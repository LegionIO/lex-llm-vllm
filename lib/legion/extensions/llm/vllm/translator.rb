# frozen_string_literal: true

require 'legion/extensions/llm/canonical'
require 'legion/extensions/llm/responses/thinking_extractor'
require 'legion/extensions/llm/stop_reason_mapping'
require 'legion/json'
require 'legion/logging'

module Legion
  module Extensions
    module Llm
      module Vllm
        # ── Message formatting helpers ────────────────────────────────────────

        # Formats canonical messages and content blocks into OpenAI wire shapes.
        module TranslatorMessageHelpers
          private

          def format_messages(request)
            non_system = request.messages&.reject { |m| m.role.to_s == 'system' } || []
            messages = format_request_messages(non_system)
            request.system.to_s.strip.empty? ? messages : prepend_system(request.system, messages)
          end

          def prepend_system(system, messages)
            [{ role: 'system', content: system.strip }] + messages
          end

          def format_request_messages(messages)
            return [] if messages.nil? || messages.empty?

            messages.map { |msg| format_message(msg) }
          end

          def format_message(msg)
            role = msg.role.to_s
            content = format_message_content(msg)
            tool_calls = format_message_tool_calls(msg.tool_calls) if msg.tool_calls&.any?
            {
              role: role, content: content,
              tool_call_id: msg.tool_call_id, tool_calls: tool_calls, name: msg.name
            }.compact.reject { |k, v| k == :name && (v.nil? || v.to_s.empty?) }
          end

          def format_message_content(msg)
            content = msg.content
            return content if content.is_a?(String) && !content.empty?

            case content
            when Array then format_content_blocks(content)
            when Canonical::ContentBlock then format_content_blocks([content])
            when Hash then format_content_blocks_from_hash(content)
            else content&.to_s
            end
          end

          def format_content_blocks(blocks)
            parts = blocks.map { |block| coerce_content_block(block) }
            parts.empty? ? '' : parts
          end

          def coerce_content_block(block)
            if block.is_a?(Canonical::ContentBlock)
              format_content_block(block)
            elsif block.is_a?(Hash)
              format_content_block_from_hash(block)
            else
              { type: 'text', text: block.to_s }
            end
          end

          def format_content_block(block)
            case block.type
            when :tool_use then { type: 'text', text: Legion::JSON.generate(block.input || {}) }
            when :image    then build_image_block(block)
            else                { type: 'text', text: block.text.to_s }
            end
          end

          def format_content_blocks_from_hash(hash_input)
            case hash_input
            when Hash  then [format_content_block_from_hash(hash_input)]
            when Array then hash_input.map { |hsh| format_content_block_from_hash(hsh) }
            else            []
            end
          end

          def format_content_block_from_hash(block_hash)
            attrs = block_hash.transform_keys(&:to_sym)
            type = (attrs[:type] || :text).to_sym
            format_block_hash_by_type(type, attrs)
          end

          def format_block_hash_by_type(type, attrs)
            case type
            when :tool_use
              { type: 'text', text: Legion::JSON.generate(attrs[:input] || {}) }
            when :image, :image_url
              { type: 'image_url', image_url: { url: attrs[:data] || attrs[:url] || '' } }
            else
              { type: 'text', text: attrs[:text].to_s }
            end
          end

          def build_image_block(block)
            return {} unless block.data || block.source_type

            url = if block.source_type == :base64 && block.media_type
                    "data:#{block.media_type};base64,#{block.data}"
                  else
                    block.data
                  end
            { type: 'image_url', image_url: { url: url } }
          end
        end

        # ── Tool-call history helpers ─────────────────────────────────────────

        # Formats tool-call entries (in assistant messages) into OpenAI wire shape.
        module TranslatorToolCallHelpers
          private

          def format_message_tool_calls(tool_calls)
            return [] if tool_calls.empty?

            tc_array = tool_calls.is_a?(Hash) ? tool_calls.values : Array(tool_calls)
            tc_array.map { |tce| format_tool_call_for_history(tce) }
          end

          def format_tool_call_for_history(tool_call_entry)
            hash = coerce_tool_call_to_hash(tool_call_entry)
            name = hash[:name] || hash['name']
            id   = hash[:id]   || hash['id']
            args = serialize_tool_args(hash)
            { id: id.to_s, type: 'function', function: { name: name.to_s, arguments: args } }
          end

          def coerce_tool_call_to_hash(entry)
            case entry
            when Canonical::ToolCall then canonical_tool_call_to_hash(entry)
            when Hash                then entry.transform_keys(&:to_sym)
            else                          entry
            end
          end

          def canonical_tool_call_to_hash(tool_call)
            { name: tool_call&.name&.to_s, id: tool_call&.id&.to_s, arguments: tool_call&.arguments || {} }
          end

          def serialize_tool_args(hash)
            args = hash[:arguments] || hash['arguments'] || {}
            args.is_a?(Hash) ? Legion::JSON.generate(args) : args.to_s
          end
        end

        # ── Tool definition helpers ───────────────────────────────────────────

        # Renders tool definitions and tool-choice hints into OpenAI wire format.
        module TranslatorToolHelpers
          private

          def format_tools(tools)
            return [] if tools.to_h.empty?

            tools.to_h.values.map { |tool| format_single_tool(tool) }
          end

          def format_single_tool(tool)
            hash = normalize_tool_to_hash(tool)
            name = hash[:name] || hash['name']
            description = (hash[:description] || hash['description'] || '').to_s
            parameters = resolve_tool_parameters(hash)
            { type: 'function', function: { name: name.to_s, description: description, parameters: parameters } }
          end

          def normalize_tool_to_hash(tool)
            if tool.is_a?(Canonical::ToolDefinition)
              { name: tool.name, description: tool.description, parameters: tool.parameters }
            elsif tool.is_a?(Hash)
              tool.transform_keys(&:to_sym)
            else
              tool
            end
          end

          def resolve_tool_parameters(hash)
            raw = hash[:parameters] || hash[:input_schema]
            raw = raw.to_h if raw.respond_to?(:to_h) && !raw.is_a?(Hash)
            Legion::Extensions::Llm::Canonical::ToolDefinition.normalize_parameters(raw)
          end

          def format_tool_choice(choice)
            return nil unless choice

            case choice
            when :auto, 'auto'         then 'auto'
            when :none, 'none'         then 'none'
            when :required, 'required' then 'required'
            when Hash                  then function_choice_from_hash(choice)
            when Symbol, String        then { type: 'function', function: { name: choice.to_s } }
            end
          end

          def function_choice_from_hash(choice)
            name = choice[:name] || choice['name']
            { type: 'function', function: { name: name.to_s } }
          end
        end

        # ── Parameter mapping helpers ─────────────────────────────────────────

        # Maps G18 canonical params to vLLM wire keys.
        module TranslatorParamHelpers
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

          private

          def map_params_to_wire(params)
            return {} unless params.is_a?(Canonical::Params)

            wire = build_supported_params_wire(params)
            log_unsupported_params(params)
            wire
          end

          def build_supported_params_wire(params)
            SUPPORTED_PARAMS.each_with_object({}) do |param_key, wire|
              value = params.public_send(param_key)
              next if value.nil?

              wire[PARAM_WIRE_KEYS[param_key]] = transform_param_value(param_key, value)
            end
          end

          def transform_param_value(param_key, value)
            case param_key
            when :stop_sequences  then format_stop_sequences(value)
            when :response_format then format_response_format_value(value)
            else value
            end
          end

          def log_unsupported_params(params)
            return unless params.max_thinking_tokens

            log.debug do
              'vLLM translator dropping unsupported params: max_thinking_tokens ' \
                '(handled via vLLM-specific render paths)'
            end
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

            val_hash = to_sym_hash(value)
            type = val_hash[:type] || val_hash['type']
            format_typed_response_format(type&.to_s, val_hash, value)
          end

          def to_sym_hash(value)
            value.is_a?(Hash) ? value.transform_keys(&:to_sym) : {}
          end

          def format_typed_response_format(type, val_hash, fallback)
            case type
            when 'json_schema' then { type: 'json_schema', json_schema: extract_json_schema(val_hash) }
            when 'json_object' then { type: 'json_object' }
            else fallback
            end
          end

          def extract_json_schema(val_hash)
            val_hash[:schema] || val_hash['schema'] || val_hash[:json_schema] || val_hash['json_schema']
          end
        end

        # ── Thinking configuration helpers ────────────────────────────────────

        # Applies thinking/reasoning config to vLLM wire payloads.
        module TranslatorThinkingHelpers
          private

          def apply_thinking_config(payload, request)
            return unless enable_thinking?(request)

            payload[:chat_template_kwargs] = { enable_thinking: true }
            budget = request.params&.max_thinking_tokens
            return unless budget&.positive?

            log.debug { "vLLM translator thinking max_thinking_tokens=#{budget} via chat template" }
          end

          def enable_thinking?(request)
            return true if thinking_object_enabled?(request.thinking)
            return true if thinking_hash_enabled?(request.thinking)
            return config_thinking_on? if request.thinking.nil?

            false
          end

          def thinking_object_enabled?(thinking)
            thinking.is_a?(Canonical::Thinking::Config) && thinking.enabled?
          end

          def thinking_hash_enabled?(thinking)
            thinking.is_a?(Hash) && (thinking[:enabled] != false)
          end

          def config_thinking_on?
            return false unless config

            config_thinking_enabled?
          end

          def config_thinking_enabled?
            val = config.respond_to?(:enable_thinking) ? config.enable_thinking : config_bracket_thinking
            val == true
          end

          def config_bracket_thinking
            config.respond_to?(:[]) ? config[:enable_thinking] : nil
          end
        end

        # ── Tool-call parsing helpers ─────────────────────────────────────────

        # Parses wire tool-call payloads and synthesizes tool calls from text content.
        module TranslatorToolCallParseHelpers
          private

          def parse_tool_arguments(arguments)
            return {} if arguments.nil? || arguments == ''
            return arguments if arguments.is_a?(Hash)

            Legion::JSON.load(arguments)
          rescue Legion::JSON::ParseError
            {}
          end

          def synthesize_tool_calls_from_content(content, _message)
            return [] unless content.is_a?(String) && !content.empty?

            tool_call = try_parse_tool_call_from_text(content)
            return [tool_call] if tool_call

            json_match = content.match(/\{[^{}]*(?:tool|function|name|arguments)[^{}]*\}/m)
            return [] unless json_match

            found = try_parse_tool_call_from_text(json_match[0])
            found ? [found] : []
          end

          def try_parse_tool_call_from_text(text)
            parsed = Legion::JSON.load(text)
            return nil unless parsed.is_a?(Hash)

            name = parsed[:name] || parsed[:function_name]
            return nil if name.nil? || name.to_s.empty?

            args = resolve_tool_args(parsed)
            Canonical::ToolCall.build(name: name.to_s, arguments: args, source: :client)
          rescue Legion::JSON::ParseError
            nil
          end

          def resolve_tool_args(parsed)
            raw = parsed[:arguments] || parsed[:parameters] || parsed[:input] || {}
            raw = Legion::JSON.load(raw) if raw.is_a?(String)
            raw.is_a?(Hash) ? raw : {}
          rescue Legion::JSON::ParseError
            {}
          end
        end

        # ── Response parsing helpers ──────────────────────────────────────────

        # Parses vLLM/OpenAI-compatible completion responses into Canonical::Response.
        module TranslatorResponseHelpers
          private

          def canonical_error_response(wire)
            body = wire.is_a?(Hash) ? wire : {}
            error_info = body['error'] || { type: 'parse_error', message: 'Failed to parse response' }
            Canonical::Response.build(
              text: '', tool_calls: [],
              usage: Canonical::Usage.from_hash(body['usage'] || {}),
              stop_reason: :error, model: body['model'],
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

            Canonical::Thinking.new(content: extraction.thinking, signature: extraction.signature)
          end

          def resolve_tool_calls(extraction, message)
            tool_calls = parse_tool_calls(message['tool_calls'])
            if tool_calls.empty?
              synthesized = synthesize_tool_calls_from_content(extraction.content, message)
              tool_calls.concat(synthesized)
            end
            tool_calls
          end

          def parse_tool_calls(tool_calls)
            return [] unless tool_calls.is_a?(Array) && !tool_calls.empty?

            tool_calls.filter_map do |call|
              function = call.fetch('function', {})
              name = function['name']
              id = call['id'] || name || call['index']
              Canonical::ToolCall.build(id: id.to_s, name: name.to_s,
                                        arguments: parse_tool_arguments(function['arguments']),
                                        source: :client)
            rescue StandardError => e
              handle_exception(e, level: :warn, handled: true, operation: 'vllm.translator.parse_tool_call')
              nil
            end
          end

          def wire_metadata(wire, message, _thinking_meta)
            meta = {}
            reasoning = message['reasoning_content'] || message['reasoning']
            meta[:reasoning_content] = reasoning if reasoning
            raw_usage = wire['usage']
            if raw_usage.is_a?(Hash) && raw_usage['completion_tokens_details']
              meta[:completion_tokens_details] = raw_usage['completion_tokens_details']
            end
            meta
          end

          def build_canonical_response(wire)
            choice = Array(wire['choices']).first || {}
            message = choice['message'] || {}
            thinking_meta = extract_thinking_metadata(message)
            extraction = Responses::ThinkingExtractor.extract(
              message['content'] || '', metadata: thinking_meta
            )
            assemble_canonical_response(wire, message, choice, extraction, thinking_meta)
          end

          def assemble_canonical_response(wire, message, choice, extraction, thinking_meta)
            Canonical::Response.build(
              text: (extraction.content || '').to_s,
              thinking: build_canonical_thinking(extraction),
              tool_calls: resolve_tool_calls(extraction, message),
              usage: Canonical::Usage.from_hash(wire['usage'] || {}),
              stop_reason: map_stop_reason(choice['finish_reason']),
              model: wire['model'],
              metadata: wire_metadata(wire, message, thinking_meta)
            )
          end
        end

        # ── Chunk builder helpers ─────────────────────────────────────────────

        # Builds specific Canonical::Chunk variants used by TranslatorChunkHelpers.
        module TranslatorChunkBuilderHelpers
          private

          def build_thinking_delta_chunk(reasoning, content, request_id, stop_reason:, usage:)
            no_content = content.to_s.empty?
            Canonical::Chunk.thinking_delta(
              delta: reasoning, request_id: request_id,
              block_index: nil, item_id: nil,
              stop_reason: no_content ? stop_reason : nil,
              usage: no_content ? usage : nil
            )
          end

          def build_done_chunk(data)
            Canonical::Chunk.done(
              request_id: data['request_id'] || data['id'],
              usage: Canonical::Usage.from_hash(data['usage']),
              stop_reason: nil
            )
          end

          # Build a tool_call_delta chunk preserving OpenAI streaming fragment semantics.
          # Opening fragments carry id + name; continuation fragments carry id: nil and a
          # partial-JSON arguments string. StreamAccumulator keys off nil id to append.
          def build_tool_call_delta_chunk(first_call, request_id, stop_reason: nil, usage: nil)
            function = first_call.fetch('function', {})
            tc = Canonical::ToolCall.new(
              id: first_call['id'], exchange_id: nil,
              name: function['name'], arguments: function['arguments'].to_s,
              source: :client, status: nil, duration_ms: nil, result: nil,
              error: nil, started_at: nil, finished_at: nil, category: nil,
              data_handling_classification: nil, policy_decision: nil
            )
            Canonical::Chunk.tool_call_delta(
              tool_call: tc, request_id: request_id,
              block_index: first_call['index'], stop_reason: stop_reason, usage: usage
            )
          end

          def parse_text_delta_with_thinking(content, request_id, data, stop_reason: nil, usage: nil)
            Canonical::Chunk.text_delta(
              delta: content, request_id: request_id, index: data['index'],
              stop_reason: stop_reason, usage: usage
            )
          end
        end

        # ── Chunk parsing helpers ─────────────────────────────────────────────

        # Parses vLLM SSE stream chunks into Canonical::Chunk objects.
        module TranslatorChunkHelpers
          FALLBACK_STOP_REASON = :end_turn

          private

          def coerce_chunk_input(raw)
            return nil if raw.nil?
            return nil if raw.is_a?(String) && (raw == '[DONE]' || raw.strip.empty?)

            raw.is_a?(Hash) ? raw : parse_json_safely(raw)
          end

          def error_chunk_from_hash(data)
            Canonical::Chunk.error_chunk(error: data['error'], request_id: data['id'])
          end

          def parse_openai_chunk(data)
            choice = Array(data['choices']).first
            return build_done_chunk(data) if choice.nil? && data['usage']
            return nil unless choice

            parse_openai_choice(choice, data)
          end

          def parse_openai_choice(choice, data)
            delta = choice['delta'] || {}
            finish_reason = choice['finish_reason']
            request_id = data['request_id'] || data['id']
            return done_from_finish(data, request_id, finish_reason) if finish_reason && empty_delta?(delta)

            parse_delta_content(delta, request_id, finish_reason, data)
          end

          def done_from_finish(data, request_id, finish_reason)
            Canonical::Chunk.done(
              request_id: request_id,
              usage: Canonical::Usage.from_hash(data['usage']),
              stop_reason: map_stop_reason(finish_reason)
            )
          end

          def parse_delta_content(delta, request_id, finish_reason, data)
            stop_reason = finish_reason ? map_stop_reason(finish_reason) : nil
            usage = finish_reason && data['usage'] ? Canonical::Usage.from_hash(data['usage']) : nil
            tool_calls = Array(delta['tool_calls'])
            unless tool_calls.empty?
              return build_tool_call_chunks(tool_calls, delta['content'], request_id, stop_reason, usage)
            end

            parse_thinking_or_text_delta(delta, request_id, stop_reason: stop_reason, usage: usage)
          end

          def build_tool_call_chunks(tool_calls, delta_content, request_id, stop_reason, usage)
            if delta_content && !delta_content.to_s.empty?
              log.debug '[vllm][translator] action=content_dropped_with_tool_call ' \
                        "content=#{delta_content[0, 100].inspect} request_id=#{request_id}"
            end
            chunks = tool_calls.map do |tc|
              build_tool_call_delta_chunk(tc, request_id, stop_reason: stop_reason, usage: usage)
            end
            chunks.size == 1 ? chunks.first : chunks
          end

          def parse_thinking_or_text_delta(delta, request_id, stop_reason:, usage:)
            reasoning = delta['reasoning_content'] || delta['reasoning']
            unless reasoning.to_s.empty?
              return parse_reasoning_delta(reasoning, delta['content'], request_id,
                                           stop_reason: stop_reason, usage: usage)
            end
            content = delta['content']
            return nil if content.to_s.empty?

            parse_text_delta_with_thinking(content, request_id, delta, stop_reason: stop_reason, usage: usage)
          end

          def parse_reasoning_delta(reasoning, content, request_id, stop_reason:, usage:)
            thinking_chunk = build_thinking_delta_chunk(reasoning, content, request_id,
                                                        stop_reason: stop_reason, usage: usage)
            return thinking_chunk if content.to_s.empty?

            content_chunk = parse_text_delta_with_thinking(content, request_id, {},
                                                           stop_reason: stop_reason, usage: usage)
            [thinking_chunk, content_chunk]
          end

          def blank_field?(value)
            value.nil? || value.to_s.empty?
          end

          def array_blank?(value)
            value.nil? || Array(value).empty?
          end

          def empty_delta?(delta)
            blank_field?(delta['content']) &&
              array_blank?(delta['tool_calls']) &&
              blank_field?(delta['reasoning_content']) &&
              blank_field?(delta['reasoning'])
          end

          def canonical_response?(wire)
            wire.key?('text') || wire['text'] || wire.key?(:stop_reason) || wire.key?('stop_reason')
          end

          def handle_canonical_chunk(data)
            Canonical::Chunk.from_hash(data)
          rescue StandardError => e
            log.debug { "vLLM translator canonical chunk parse error: #{e.message}" }
            nil
          end

          def map_stop_reason(raw)
            return FALLBACK_STOP_REASON if raw.nil? || raw.to_s.empty?

            stop_reason_lookup(raw) || FALLBACK_STOP_REASON
          end

          def parse_json_safely(raw)
            return nil unless raw.is_a?(String)

            Legion::JSON.load(raw)
          rescue Legion::JSON::ParseError => e
            log.debug { "vLLM translator chunk parse error: #{e.message}" }
            nil
          end
        end

        # ── Render helpers ────────────────────────────────────────────────────

        # Private render-request helpers extracted from Translator to reduce ClassLength.
        module TranslatorRenderHelpers
          private

          # OpenAI `stream_options.include_usage` asks the server to emit a final
          # usage-only chunk (choices:[]) so streaming responses carry token counts.
          # vLLM supports it; a non-conforming backend can opt out per-instance via
          # config[:stream_token_usage] = false.
          def stream_token_usage?
            override = config.respond_to?(:[]) ? config[:stream_token_usage] : nil
            return override != false unless override.nil?

            capabilities[:streaming_token_usage] == true
          end

          def extract_wire_model(request)
            meta = request.metadata || {}
            model = meta[:model] || meta['model']
            raise ArgumentError, 'vllm.render_request: no model in request; routing must select a model' \
              if model.nil? || model.to_s.strip.empty?

            model
          end

          def apply_payload_options(payload, request)
            apply_tools_to_payload(payload, request)
            apply_params_to_payload(payload, request)
            apply_thinking_config(payload, request)
            apply_response_format_to_payload(payload, request)
          end

          def apply_tools_to_payload(payload, request)
            return if request.tools.to_h.empty?

            payload[:tools] = format_tools(request.tools)
            payload[:tool_choice] = format_tool_choice(request.tool_choice) if request.tool_choice
          end

          def apply_params_to_payload(payload, request)
            payload.merge!(map_params_to_wire(request.params)) if request.params
            payload[:stream_options] = { include_usage: true } if request.stream && stream_token_usage?
          end

          def apply_response_format_to_payload(payload, request)
            return unless formatted_response_format?(request.params)

            payload[:response_format] = format_response_format(request.params)
          end

          def log_rendered_request(model, messages, request, payload)
            log.debug do
              "vLLM translator rendered request model=#{model} stream=#{request.stream} " \
                "messages=#{messages.size} tools=#{request.tools&.size || 0} params=#{payload.keys.size}"
            end
          end
        end

        # ── Translator class ──────────────────────────────────────────────────

        # Canonical provider translator for vLLM (OpenAI-compatible wire format).
        #
        # Implements render_request, parse_response, parse_chunk, and capabilities.
        #
        # vLLM quirks declared in capabilities:
        # - tool_calls_as_text: true  — some models output tool calls as JSON text.
        # - forced_tool_choice: true  — named tool choices require explicit references.
        # - thinking_tags: %w[think thinking] — Qwen-style reasoning in <think> tags.
        class Translator
          include Legion::Logging::Helper
          include Legion::Extensions::Llm::StopReasonMapping
          include TranslatorMessageHelpers
          include TranslatorToolCallHelpers
          include TranslatorToolHelpers
          include TranslatorParamHelpers
          include TranslatorThinkingHelpers
          include TranslatorToolCallParseHelpers
          include TranslatorResponseHelpers
          include TranslatorChunkBuilderHelpers
          include TranslatorChunkHelpers
          include TranslatorRenderHelpers

          def initialize(config: nil)
            @config = config
          end

          def render_request(request)
            model = extract_wire_model(request)
            messages = format_messages(request)
            payload = { model: model, messages: messages, stream: request.stream }
            apply_payload_options(payload, request)
            log_rendered_request(model, messages, request, payload)
            payload
          end

          def parse_response(wire)
            return canonical_error_response(wire) unless wire.is_a?(Hash)
            return Canonical::Response.from_hash(wire) if canonical_response?(wire)

            build_canonical_response(wire)
          rescue Legion::JSON::ParseError => e
            handle_exception(e, level: :warn, handled: true, operation: 'vllm.translator.parse_response')
            canonical_error_response(wire)
          rescue StandardError => e
            handle_exception(e, level: :error, handled: false, operation: 'vllm.translator.parse_response')
            raise
          end

          def parse_chunk(raw)
            data = coerce_chunk_input(raw)
            return nil if data.nil?
            return handle_canonical_chunk(data) if data['type']
            return error_chunk_from_hash(data) if data['error']

            parse_openai_chunk(data)
          rescue Legion::JSON::ParseError => e
            handle_exception(e, level: :warn, handled: true, operation: 'vllm.translator.parse_chunk')
            nil
          rescue StandardError => e
            handle_exception(e, level: :error, handled: false, operation: 'vllm.translator.parse_chunk')
            raise
          end

          def capabilities
            {
              provider: 'vllm',
              wire_format: 'openai_compatible',
              tool_calls_as_text: true,
              forced_tool_choice: true,
              thinking_tags: %w[think thinking],
              stop_reason_map: stop_reason_map,
              streaming_token_usage: true
            }.freeze
          end

          private

          attr_reader :config
        end
      end
    end
  end
end
