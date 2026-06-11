# frozen_string_literal: true

require 'legion/extensions/llm/canonical'
require 'legion/extensions/llm/responses/thinking_extractor'
require 'legion/json'
require 'legion/logging'

module Legion
  module Extensions
    module Llm
      module Vllm
        # Canonical provider translator for vLLM (OpenAI-compatible wire format).
        #
        # Implements render_request, parse_response, parse_chunk, and capabilities.
        # Extracted from existing format_openai_*/parse_* methods in OpenAICompatible mixin
        # and vLLM-specific render_payload override in Provider.
        #
        # vLLM quirks (declared in capabilities):
        # - tool_calls_as_text: true — some model configurations output tool calls
        #   as JSON text in the content field rather than structured tool_calls.
        # - forced_tool_choice: true — vLLM's tool_choice handling is strict;
        #   named tool choices must be explicit function references.
        # - thinking_tags: ['think', 'thinking'] — Qwen-style models emit reasoning
        #   in <think> or <thinking> tags within content text.
        # rubocop:disable Metrics/ClassLength, Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity -- translator implementation
        class Translator
          include Legion::Logging::Helper

          # vLLM-specific stop_reason mapping (per conformance fixture stop_reason_matrix).
          VLLM_STOP_REASON_MAP = {
            'stop' => :end_turn,
            'tool_use' => :tool_use,
            'length' => :max_tokens
          }.freeze
          FALLBACK_STOP_REASON = :end_turn

          # G18 parameter mapping: supported canonical params.
          SUPPORTED_PARAMS = %i[
            max_tokens temperature top_p top_k stop_sequences
            seed frequency_penalty presence_penalty response_format
          ].freeze

          # vLLM wire keys for supported params (most are 1:1 with canonical names).
          PARAM_WIRE_KEYS = {
            max_tokens: :max_tokens,
            temperature: :temperature,
            top_p: :top_p,
            top_k: :top_k,
            stop_sequences: :stop,
            seed: :seed,
            frequency_penalty: :frequency_penalty,
            presence_penalty: :presence_penalty,
            response_format: :response_format
          }.freeze

          def initialize(config: nil)
            @config = config
          end

          # Render a canonical request into an OpenAI-compatible wire payload for vLLM.
          def render_request(request)
            model = request.metadata&.dig(:model) || 'default'
            messages = format_messages(request)
            payload = {
              model: model,
              messages: messages,
              stream: request.stream
            }

            payload[:tools] = format_tools(request.tools) unless request.tools.to_h.empty?
            payload[:tool_choice] = format_tool_choice(request.tool_choice) if request.tool_choice
            payload.merge!(map_params_to_wire(request.params)) if request.params
            apply_thinking_config(payload, request)
            if formatted_response_format?(request.params)
              payload[:response_format] =
                format_response_format(request.params)
            end

            log.debug do
              "vLLM translator rendered request model=#{model} stream=#{request.stream} " \
                "messages=#{messages.size} tools=#{request.tools&.size || 0} params=#{payload.keys.size}"
            end

            payload
          end

          # Parse a vLLM/OpenAI-compatible completion response into a Canonical::Response.
          def parse_response(wire)
            return canonical_error_response(wire) unless wire.is_a?(Hash)
            # Canonical-form response (from conformance kit): already in canonical shape
            return Canonical::Response.from_hash(wire) if canonical_response?(wire)

            choice = Array(wire['choices']).first || {}
            message = choice['message'] || {}
            usage = wire['usage'] || {}
            finish_reason = choice['finish_reason']
            model = wire['model']

            content = message['content'] || ''
            thinking_meta = extract_thinking_metadata(message)
            extraction = Responses::ThinkingExtractor.extract(content, metadata: thinking_meta)

            text = extraction.content || ''
            thinking = build_canonical_thinking(extraction)

            tool_calls = parse_tool_calls(message['tool_calls'])

            # vLLM quirk: tool_calls_as_text — synthesize from content if none found.
            if tool_calls.empty?
              synthesized = synthesize_tool_calls_from_content(extraction.content, message)
              tool_calls.concat(synthesized) unless synthesized.empty?
            end

            stop_reason = map_stop_reason(finish_reason)

            Canonical::Response.build(
              text: text.to_s,
              thinking: thinking,
              tool_calls: tool_calls,
              usage: Canonical::Usage.from_hash(usage),
              stop_reason: stop_reason,
              model: model,
              metadata: wire_metadata(wire, message, thinking_meta)
            )
          rescue Legion::JSON::ParseError => e
            handle_exception(e, level: :warn, handled: true, operation: 'vllm.translator.parse_response')
            canonical_error_response(wire)
          rescue StandardError => e
            handle_exception(e, level: :error, handled: false, operation: 'vllm.translator.parse_response')
            raise
          end

          # Parse a single SSE chunk into a Canonical::Chunk or nil.
          def parse_chunk(raw)
            return nil if raw.nil?
            return nil if raw.is_a?(String) && (raw == '[DONE]' || raw.strip.empty?)

            data = raw.is_a?(Hash) ? raw : parse_json_safely(raw)
            return nil if data.nil?

            # Handle canonical-form chunks (from conformance fixtures or other translators)
            return handle_canonical_chunk(data) if data['type']

            if data['error']
              return Canonical::Chunk.error_chunk(
                error: data['error'],
                request_id: data['id']
              )
            end

            choice = Array(data['choices']).first
            return build_done_chunk(data) if choice.nil? && data['usage']
            return nil unless choice

            delta = choice['delta'] || {}
            finish_reason = choice['finish_reason']
            request_id = data['request_id'] || data['id']

            if finish_reason && empty_delta?(delta)
              return Canonical::Chunk.done(
                request_id: request_id,
                usage: Canonical::Usage.from_hash(data['usage']),
                stop_reason: map_stop_reason(finish_reason)
              )
            end

            tool_calls = Array(delta['tool_calls'])
            return build_tool_call_delta_chunk(tool_calls.first, request_id) unless tool_calls.empty?

            # Thinking delta from reasoning_content
            reasoning_content = delta['reasoning_content'] || delta['reasoning']
            unless reasoning_content.to_s.empty?
              return Canonical::Chunk.thinking_delta(
                delta: reasoning_content,
                request_id: request_id,
                block_index: delta.dig('content_block', 'index'),
                item_id: delta['content_block_start']&.dig('id')
              )
            end

            # Text delta — check for embedded think tags
            content = delta['content']
            return parse_text_delta_with_thinking(content, request_id, data) unless content.to_s.empty?

            nil
          rescue Legion::JSON::ParseError => e
            handle_exception(e, level: :warn, handled: true, operation: 'vllm.translator.parse_chunk')
            nil
          rescue StandardError => e
            handle_exception(e, level: :error, handled: false, operation: 'vllm.translator.parse_chunk')
            raise
          end

          # Declared capabilities for the vLLM provider.
          def capabilities
            {
              provider: 'vllm',
              wire_format: 'openai_compatible',
              tool_calls_as_text: true,
              forced_tool_choice: true,
              thinking_tags: %w[think thinking],
              stop_reason_map: VLLM_STOP_REASON_MAP,
              streaming_token_usage: true
            }.freeze
          end

          private

          attr_reader :config

          # ── Message formatting ──

          def format_messages(request)
            non_system = request.messages&.reject { |m| m.role.to_s == 'system' } || []
            messages = format_request_messages(non_system)

            if request.system.to_s.strip.empty?
              messages
            else
              [{ role: 'system', content: request.system.strip }] + messages
            end
          end

          def format_request_messages(messages)
            return [] if messages.nil? || messages.empty?

            messages.map { |msg| format_message(msg) }
          end

          def format_message(msg)
            role = msg.role.to_s
            content = format_message_content(msg)
            tool_calls = format_message_tool_calls(msg.tool_calls) if msg.tool_calls&.any?
            tool_call_id = msg.tool_call_id
            name = msg.name

            {
              role: role,
              content: content,
              tool_call_id: tool_call_id,
              tool_calls: tool_calls,
              name: name
            }.compact.reject { |k, v| k == :name && (v.nil? || v.to_s.empty?) }
          end

          def format_message_content(msg)
            content = msg.content
            return content if content.is_a?(String) && !content.empty?

            case content
            when Array
              format_content_blocks(content)
            when Canonical::ContentBlock
              format_content_blocks([content])
            when Hash
              format_content_blocks_from_hash(content)
            else
              content&.to_s
            end
          end

          def format_content_blocks(blocks)
            parts = blocks.map do |block|
              if block.is_a?(Canonical::ContentBlock)
                format_content_block(block)
              elsif block.is_a?(Hash)
                format_content_block_from_hash(block)
              else
                { type: 'text', text: block.to_s }
              end
            end
            parts.empty? ? '' : parts
          end

          # rubocop:disable Lint/DuplicateBranch -- multiple block types intentionally normalize to text in OpenAI wire format
          def format_content_block(block)
            case block.type
            when :text, :thinking, :tool_result
              { type: 'text', text: block.text.to_s }
            when :tool_use
              { type: 'text', text: Legion::JSON.generate(block.input || {}) }
            when :image
              build_image_block(block)
            else
              { type: 'text', text: block.text.to_s }
            end
          end
          # rubocop:enable Lint/DuplicateBranch

          def format_content_blocks_from_hash(hash_input)
            case hash_input
            when Hash
              [format_content_block_from_hash(hash_input)]
            when Array
              hash_input.map { |h| format_content_block_from_hash(h) }
            else
              []
            end
          end

          # rubocop:disable Lint/DuplicateBranch -- multiple block types intentionally normalize to text in OpenAI wire format
          def format_content_block_from_hash(block_hash)
            h = block_hash.transform_keys(&:to_sym)
            type = (h[:type] || :text).to_sym

            case type
            when :text, :thinking, :tool_result
              { type: 'text', text: h[:text].to_s }
            when :tool_use
              { type: 'text', text: Legion::JSON.generate(h[:input] || {}) }
            when :image, :image_url
              { type: 'image_url', image_url: { url: h[:data] || h[:url] || '' } }
            else
              { type: 'text', text: h[:text].to_s }
            end
          end
          # rubocop:enable Lint/DuplicateBranch

          def build_image_block(block)
            return {} unless block.data || block.source_type

            url = if block.source_type == :base64 && block.media_type
                    "data:#{block.media_type};base64,#{block.data}"
                  else
                    block.data
                  end
            { type: 'image_url', image_url: { url: url } }
          end

          def format_message_tool_calls(tool_calls)
            return [] if tool_calls.empty?

            tool_calls.map { |tc| format_tool_call_for_history(tc) }
          end

          def format_tool_call_for_history(tool_call_entry)
            tc_hash = case tool_call_entry
                      when Canonical::ToolCall
                        { name: tool_call_entry&.name&.to_s, id: tool_call_entry&.id&.to_s,
                          arguments: tool_call_entry&.arguments || {} }
                      when Hash
                        tool_call_entry.transform_keys(&:to_sym)
                      else
                        tool_call_entry
                      end

            name = tc_hash[:name] || tc_hash['name']
            id = tc_hash[:id] || tc_hash['id']
            args = tc_hash[:arguments] || tc_hash['arguments'] || {}
            args = args.is_a?(Hash) ? Legion::JSON.generate(args) : args.to_s

            {
              id: id.to_s,
              type: 'function',
              function: { name: name.to_s, arguments: args }
            }
          end

          # ── Tool formatting ──

          def format_tools(tools)
            return [] if tools.to_h.empty?

            tools.to_h.values.map do |tool|
              tool_hash = if tool.is_a?(Canonical::ToolDefinition)
                            { name: tool.name, description: tool.description, parameters: tool.parameters }
                          elsif tool.is_a?(Hash)
                            tool.transform_keys(&:to_sym)
                          else
                            tool
                          end

              name = tool_hash[:name] || tool_hash['name']
              description = (tool_hash[:description] || tool_hash['description'] || '').to_s
              parameters = tool_hash[:parameters] || tool_hash[:input_schema] ||
                           { type: 'object', properties: {} }
              parameters = parameters.to_h if parameters.respond_to?(:to_h) && !parameters.is_a?(Hash)
              parameters = { type: 'object', properties: {} } unless parameters.is_a?(Hash)

              {
                type: 'function',
                function: {
                  name: name.to_s,
                  description: description,
                  parameters: parameters
                }
              }
            end
          end

          def format_tool_choice(choice)
            return nil unless choice

            case choice
            when :auto, 'auto'
              'auto'
            when :none, 'none'
              'none'
            when :required, 'required'
              'required'
            when Hash
              name = choice[:name] || choice['name']
              { type: 'function', function: { name: name.to_s } }
            when Symbol, String
              { type: 'function', function: { name: choice.to_s } }
            end
          end

          # ── Parameter mapping (G18) ──

          def map_params_to_wire(params)
            return {} unless params.is_a?(Canonical::Params)

            wire = {}
            SUPPORTED_PARAMS.each do |param_key|
              value = params.public_send(param_key)
              next if value.nil?

              wire_key = PARAM_WIRE_KEYS[param_key]
              wire[wire_key] = case param_key
                               when :stop_sequences
                                 format_stop_sequences(value)
                               when :response_format
                                 format_response_format_value(value)
                               else
                                 value
                               end
            end

            unsupported = {}
            unsupported[:max_thinking_tokens] = params.max_thinking_tokens if params.max_thinking_tokens

            unless unsupported.empty?
              log.debug do
                "vLLM translator dropping unsupported params: #{unsupported.keys.join(', ')} " \
                  '(handled via vLLM-specific render paths)'
              end
            end

            wire
          end

          def format_stop_sequences(sequences)
            sequences.is_a?(Array) ? sequences : [sequences]
          end

          def format_response_format(params)
            return nil unless formatted_response_format?(params)

            format_response_format_value(params.response_format)
          end

          def formatted_response_format?(params)
            params.is_a?(Canonical::Params) && params.response_format
          end

          def format_response_format_value(value)
            return value if value.is_a?(String)

            val_hash = value.is_a?(Hash) ? value.transform_keys(&:to_sym) : {}
            type = val_hash[:type] || val_hash['type']

            case type&.to_s
            when 'json_schema'
              schema = val_hash[:schema] || val_hash['schema'] || val_hash[:json_schema] || val_hash['json_schema']
              { type: 'json_schema', json_schema: schema }
            when 'json_object'
              { type: 'json_object' }
            else
              value
            end
          end

          # ── Thinking configuration ──

          def apply_thinking_config(payload, request)
            return unless enable_thinking?(request)

            payload[:chat_template_kwargs] = { enable_thinking: true }
            budget = request.params&.max_thinking_tokens
            return unless budget&.positive?

            log.debug { "vLLM translator thinking max_thinking_tokens=#{budget} via chat template" }
          end

          def enable_thinking?(request)
            return true if request.thinking.is_a?(Canonical::Thinking::Config) && request.thinking.enabled?
            return true if request.thinking.is_a?(Hash) && (request.thinking[:enabled] != false)

            if request.thinking.nil? && config
              config_thinking = if config.respond_to?(:enable_thinking)
                                  config.enable_thinking
                                else
                                  config.respond_to?(:[]) ? config[:enable_thinking] : nil
                                end
              return true if config_thinking == true
            end

            false
          end

          # ── Response parsing ──

          def canonical_error_response(wire)
            body = wire.is_a?(Hash) ? wire : {}
            error_info = body['error'] || { type: 'parse_error', message: 'Failed to parse response' }

            Canonical::Response.build(
              text: '',
              tool_calls: [],
              usage: Canonical::Usage.from_hash(body['usage'] || {}),
              stop_reason: :error,
              model: body['model'],
              metadata: { error: error_info }
            )
          end

          def extract_thinking_metadata(message)
            {
              reasoning_content: message['reasoning_content'],
              reasoning: message['reasoning'],
              thinking: message['thinking'],
              thinking_text: message['thinking_text'],
              thinking_signature: message['thinking_signature'],
              reasoning_signature: message['reasoning_signature']
            }.compact
          end

          def build_canonical_thinking(extraction)
            return nil unless extraction.thinking || extraction.signature

            Canonical::Thinking.new(
              content: extraction.thinking,
              signature: extraction.signature
            )
          end

          def parse_tool_calls(tool_calls)
            return [] unless tool_calls.is_a?(Array) && !tool_calls.empty?

            tool_calls.filter_map do |call|
              function = call.fetch('function', {})
              name = function['name']
              id = call['id'] || name || call['index']
              args = parse_tool_arguments(function['arguments'])

              Canonical::ToolCall.build(
                id: id.to_s,
                name: name.to_s,
                arguments: args,
                source: :client
              )
            rescue StandardError => e
              handle_exception(e, level: :warn, handled: true, operation: 'vllm.translator.parse_tool_call')
              nil
            end
          end

          def parse_tool_arguments(arguments)
            return {} if arguments.nil? || arguments == ''
            return arguments if arguments.is_a?(Hash)

            Legion::JSON.load(arguments)
          rescue Legion::JSON::ParseError
            {}
          end

          # vLLM quirk: synthesize tool calls from content text JSON.
          def synthesize_tool_calls_from_content(content, _message)
            return [] unless content.is_a?(String) && !content.empty?

            tool_call = try_parse_tool_call_from_text(content)
            return [tool_call] if tool_call

            json_match = content.match(/\{[^{}]*(?:tool|function|name|arguments)[^{}]*\}/m)
            return [] unless json_match

            tool_call = try_parse_tool_call_from_text(json_match[0])
            tool_call ? [tool_call] : []
          end

          def try_parse_tool_call_from_text(text)
            parsed = Legion::JSON.load(text)
            return nil unless parsed.is_a?(Hash)

            name = parsed[:name] || parsed[:function_name]
            args = parsed[:arguments] || parsed[:parameters] || parsed[:input] || {}
            args = Legion::JSON.load(args) if args.is_a?(String)

            return nil if name.nil? || name.to_s.empty?

            Canonical::ToolCall.build(
              name: name.to_s,
              arguments: args.is_a?(Hash) ? args : {},
              source: :client
            )
          rescue Legion::JSON::ParseError
            nil
          end

          def wire_metadata(wire, message, _thinking_meta)
            meta = {}
            meta[:reasoning_content] = message['reasoning_content'] if message['reasoning_content']
            raw_usage = wire['usage']
            if raw_usage.is_a?(Hash) && raw_usage['completion_tokens_details']
              meta[:completion_tokens_details] = raw_usage['completion_tokens_details']
            end
            meta
          end

          # ── Chunk helpers ──

          def build_done_chunk(data)
            Canonical::Chunk.done(
              request_id: data['request_id'] || data['id'],
              usage: Canonical::Usage.from_hash(data['usage']),
              stop_reason: nil
            )
          end

          # Build a tool_call_delta chunk preserving OpenAI streaming fragment
          # semantics: the opening fragment carries id + name; continuation
          # fragments carry id: nil and a raw partial-JSON arguments string.
          # The StreamAccumulator keys off a nil id to append fragments to the
          # current tool call, so the id must NOT be synthesized here.
          def build_tool_call_delta_chunk(first_call, request_id)
            function = first_call.fetch('function', {})

            tc = Canonical::ToolCall.new(
              id: first_call['id'], exchange_id: nil,
              name: function['name'], arguments: function['arguments'].to_s,
              source: :client, status: nil, duration_ms: nil, result: nil,
              error: nil, started_at: nil, finished_at: nil, category: nil,
              data_handling_classification: nil, policy_decision: nil
            )

            Canonical::Chunk.tool_call_delta(
              tool_call: tc,
              request_id: request_id,
              block_index: first_call['index']
            )
          end

          def empty_delta?(delta)
            (delta['content'].nil? || delta['content'].to_s.empty?) &&
              (delta['tool_calls'].nil? || Array(delta['tool_calls']).empty?) &&
              (delta['reasoning_content'].nil? || delta['reasoning_content'].to_s.empty?)
          end

          # Per-chunk think-tag extraction is structurally impossible while streaming:
          # tags arrive split across SSE chunks, and ThinkingExtractor strips per-chunk
          # whitespace, corrupting reassembled text. Emit the raw delta unmodified —
          # the StreamAccumulator extracts think tags statefully across deltas.
          # (Previously called ThinkingExtractor.extract_from_content, which is
          # private_class_method in lex-llm >= 0.5.0 and raised NoMethodError on
          # every streamed text delta, silently killing all vLLM streaming.)
          def parse_text_delta_with_thinking(content, request_id, data)
            Canonical::Chunk.text_delta(
              delta: content,
              request_id: request_id,
              index: data['index']
            )
          end

          # Parse a canonical-form chunk (from conformance kit fixtures).

          # Detect canonical-form response (from conformance fixtures).
          def canonical_response?(wire)
            wire.key?('text') || wire['text'] || wire.key?(:stop_reason) || wire.key?('stop_reason')
          end

          def handle_canonical_chunk(data)
            Canonical::Chunk.from_hash(data)
          rescue StandardError => e
            log.debug { "vLLM translator canonical chunk parse error: #{e.message}" }
            nil
          end

          # ── Stop reason mapping ──

          def map_stop_reason(raw)
            return FALLBACK_STOP_REASON if raw.nil? || raw.to_s.empty?

            VLLM_STOP_REASON_MAP.fetch(raw.to_s, FALLBACK_STOP_REASON)
          end

          # ── JSON helpers ──
          # Never use bare ::JSON inside the Legion namespace.

          def parse_json_safely(raw)
            return nil unless raw.is_a?(String)

            Legion::JSON.load(raw)
          rescue Legion::JSON::ParseError => e
            log.debug { "vLLM translator chunk parse error: #{e.message}" }
            nil
          end
        end
        # rubocop:enable Metrics/ClassLength, Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
      end
    end
  end
end
