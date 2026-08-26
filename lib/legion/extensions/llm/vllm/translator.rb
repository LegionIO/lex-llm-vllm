# frozen_string_literal: true

require 'legion/extensions/llm/canonical'
require 'legion/extensions/llm/responses/thinking_extractor'
require 'legion/extensions/llm/responses/tool_arguments'
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

          # V11: the message boundary is strict (Canonical::Message.
          # normalize_content!: String | ContentBlock | Array<ContentBlock>
          # | nil) — the Hash poison-repair branch and the to_s catch-all
          # are deleted. A non-canonical shape is a contract error, not
          # data to repair.
          def format_message_content(msg)
            content = msg.content
            return content if content.is_a?(String) && !content.empty?
            return format_content_blocks(content) if content.is_a?(Array)
            return format_content_blocks([content]) if content.is_a?(Canonical::ContentBlock)

            nil
          end

          def format_content_blocks(blocks)
            parts = blocks.map { |block| coerce_content_block(block) }
            parts.empty? ? '' : parts
          end

          def coerce_content_block(block)
            return format_content_block(block) if block.is_a?(Canonical::ContentBlock)

            raise ArgumentError,
                  "vllm.translator: content block must be Canonical::ContentBlock, got #{block.class}"
          end

          def format_content_block(block)
            case block.type
            when :tool_use then { type: 'text', text: Legion::JSON.generate(block.input || {}) }
            when :image    then build_image_block(block)
            else                { type: 'text', text: block.text.to_s }
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

          # V11: message tool_calls are Array<Canonical::ToolCall> (the
          # canonical contract) — the Hash-shape repair branch is deleted.
          def format_message_tool_calls(tool_calls)
            return [] if tool_calls.empty?

            tool_calls.map { |tce| format_tool_call_for_history(tce) }
          end

          def format_tool_call_for_history(tool_call_entry)
            tool_call = coerce_tool_call_to_history(tool_call_entry)
            args = tool_call.arguments || {}
            { id: tool_call.id.to_s, type: 'function',
              function: { name: tool_call.name.to_s, arguments: Legion::JSON.generate(args) } }
          end

          def coerce_tool_call_to_history(entry)
            return entry if entry.is_a?(Canonical::ToolCall)

            raise ArgumentError,
                  "vllm.translator: history tool call must be Canonical::ToolCall, got #{entry.class}"
          end
        end

        # ── Tool definition helpers ───────────────────────────────────────────

        # Renders tool definitions and tool-choice hints into OpenAI wire format.
        module TranslatorToolHelpers
          private

          # V11: the tools boundary is strict (Hash<name,
          # Canonical::ToolDefinition> — enforced at the funnel by H3,
          # normalized by Canonical::Request) — the gem's own Hash-tolerant
          # schema extraction is deleted in favor of the shared strict
          # normalize_parameters.
          def format_tools(tools)
            return [] if tools.to_h.empty?

            tools.to_h.values.map { |tool| format_single_tool(tool) }
          end

          def format_single_tool(tool)
            definition = coerce_tool_definition(tool)
            parameters = Legion::Extensions::Llm::Canonical::ToolDefinition
                         .normalize_parameters(definition.parameters)
            { type: 'function',
              function: { name: definition.name.to_s, description: definition.description,
                          parameters: parameters } }
          end

          def coerce_tool_definition(tool)
            return tool if tool.is_a?(Canonical::ToolDefinition)

            raise ArgumentError,
                  "vllm.translator: tool must be Canonical::ToolDefinition, got #{tool.class}"
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

          # V11: the request boundary is strict (Canonical::Request.
          # normalize_params! — params is Canonical::Params or nil, nil
          # handled by the caller). A poison type silently rendering a
          # ZERO-param request (max_tokens/temperature/seed all dropped)
          # is a contract error, not a render path.
          def map_params_to_wire(params, **)
            unless params.is_a?(Canonical::Params)
              raise ArgumentError,
                    "vllm.translator: params must be Canonical::Params, got #{params.class}"
            end

            build_supported_params_wire(params)
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

        # Renders the canonical thinking state to the vLLM wire (V2).
        # The canonical request is the SOLE authority on thinking intent
        # (R4). A nil thinking config renders a silent wire; enabled: false
        # renders enable_thinking:false (forcing a default-ON model off);
        # enabled: true renders enable_thinking:true plus the resolved budget
        # as the dialect's documented thinking_budget. The budget axis consults
        # Thinking::Config#resolved_budget (the cross-axis derivation the
        # canonical config exists for) — there is no params dual-home.
        module TranslatorThinkingHelpers
          private

          def apply_thinking_config(payload, request, **)
            thinking = request.thinking
            return unless thinking.is_a?(Canonical::Thinking::Config)

            unless thinking.enabled
              payload[:chat_template_kwargs] = { enable_thinking: false }
              return
            end

            kwargs = { enable_thinking: true }
            budget = thinking.resolved_budget
            kwargs[:thinking_budget] = budget if budget&.positive?

            payload[:chat_template_kwargs] = kwargs
            log.debug do
              'vLLM translator thinking via chat_template_kwargs ' \
                "enable_thinking=true budget=#{kwargs[:thinking_budget].inspect}"
            end
          end
        end

        # ── Tool-call parsing helpers ─────────────────────────────────────────

        # Parses wire tool-call payloads and synthesizes tool calls from
        # text content (the declared tool_calls_as_text quirk — some
        # vLLM-served models emit tool calls as JSON text).
        #
        # V4: attribution is not a fact a provider response can know —
        # response tool calls carry source: nil. The executor resolves the
        # execution authority by tool NAME from the request's tool map and
        # stamps the actual source at execution; stamping :client on every
        # response call was a reconstructed attribution fact.
        module TranslatorToolCallParseHelpers
          private

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

            Canonical::ToolCall.build(name: name.to_s, arguments: resolve_tool_args(parsed))
          rescue Legion::JSON::ParseError
            nil
          end

          # V4: unparseable arguments fail the call — the same strict
          # policy as the structured sync path (ToolArguments.parse!).
          # The rescued-into-fabricated-{} policy is deleted: an
          # empty-argument tool execution is worse than a loud failure.
          def resolve_tool_args(parsed)
            raw = parsed[:arguments] || parsed[:parameters] || parsed[:input] || {}
            return raw if raw.is_a?(Hash)

            Legion::Extensions::Llm::Responses::ToolArguments.parse!(raw)
          end
        end

        # ── Response parsing helpers ──────────────────────────────────────────

        # Parses vLLM/OpenAI-compatible completion responses into Canonical::Response.
        module TranslatorResponseHelpers
          private

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

          # V1: the shared strict factory — the raw Data#new bypass is
          # deleted (under the H1 strict constructor it was also a latent
          # missing-keyword crash: metadata has no default).
          def build_canonical_thinking(extraction)
            return nil unless extraction.thinking || extraction.signature

            Canonical::Thinking.build(content: extraction.thinking, signature: extraction.signature)
          end

          def resolve_tool_calls(extraction, message)
            tool_calls = parse_tool_calls(message['tool_calls'])
            if tool_calls.empty?
              synthesized = synthesize_tool_calls_from_content(extraction.content, message)
              tool_calls.concat(synthesized)
            end
            tool_calls
          end

          # Sync tool calls. V4: no source stamp — attribution is the
          # executor's fact, not the provider's.
          #
          # Arguments resilience (rule 9): the tool CALL is the essential fact;
          # losing it because the arguments payload isn't a clean JSON-object
          # string is strictly worse than an empty-args call — the model called
          # a tool but the client sees prose (the "random canary narration"
          # regression). vLLM/qwen-family models return arguments in varying
          # shapes run-to-run (a JSON string, an already-decoded Hash, or a
          # degraded non-object like a bare number). Parse strictly; on a
          # non-object/unparseable payload, log loudly and default to {} so the
          # call still reaches the executor/client. A Hash is already decoded —
          # pass it through.
          def parse_tool_calls(tool_calls)
            return [] unless tool_calls.is_a?(Array) && !tool_calls.empty?

            tool_calls.map do |call|
              function = call.fetch('function', {})
              name = function['name']
              id = call['id'] || name || call['index']
              Canonical::ToolCall.build(
                id: id.to_s, name: name.to_s,
                arguments: parse_tool_call_arguments(function['arguments'], name)
              )
            end
          end

          def parse_tool_call_arguments(raw, tool_name)
            return raw if raw.is_a?(Hash)

            Responses::ToolArguments.parse!(raw)
          rescue ArgumentError => e
            log.warn(
              "[llm][vllm][translator] action=tool_args_parse_failed tool=#{tool_name} " \
              "error=#{e.message} — preserving the tool call with empty arguments"
            )
            {}
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

          # Edge translation (O03a): vLLM speaks the OpenAI Chat wire usage
          # dialect (prompt_tokens/completion_tokens + nested *_details).
          # lex-llm 0.8.0's Canonical::Usage.from_hash reads canonical keys
          # ONLY — the wire spellings must be normalized HERE, at the
          # provider-translator boundary, or they fold into metadata and
          # input/output_tokens resolve to nil (rendered 0). Canonical::Usage
          # stays the SSOT: from_hash({}) is the valid all-nil no-usage object
          # (never nil) for an absent wire usage.
          def canonical_usage(raw)
            return Canonical::Usage.from_hash({}) if raw.nil? || raw.empty?

            source = raw.transform_keys { |key| key.respond_to?(:to_sym) ? key.to_sym : key }
            Canonical::Usage.build(
              input_tokens: source[:input_tokens] || source[:prompt_tokens],
              output_tokens: source[:output_tokens] || source[:completion_tokens],
              cache_read_tokens: extract_nested_cached_tokens(raw),
              thinking_tokens: extract_nested_reasoning_tokens(raw)
            )
          end

          def extract_nested_cached_tokens(raw)
            raw.dig(:prompt_tokens_details, :cached_tokens) ||
              raw.dig('prompt_tokens_details', 'cached_tokens') ||
              raw.dig(:input_tokens_details, :cached_tokens) ||
              raw.dig('input_tokens_details', 'cached_tokens')
          end

          def extract_nested_reasoning_tokens(raw)
            raw.dig(:completion_tokens_details, :reasoning_tokens) ||
              raw.dig('completion_tokens_details', 'reasoning_tokens') ||
              raw.dig(:output_tokens_details, :reasoning_tokens) ||
              raw.dig('output_tokens_details', 'reasoning_tokens')
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
              usage: canonical_usage(wire['usage']),
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
              usage: canonical_usage(data['usage']),
              stop_reason: nil
            )
          end

          # Build a tool_call_delta chunk preserving OpenAI streaming fragment semantics.
          # The tool_call member is the delta FRAGMENT (the documented Chunk shape):
          # opening fragments carry id + name; continuation fragments carry id: nil and a
          # partial-JSON arguments string. StreamAccumulator correlates on the wire
          # index and appends by nil id. A full Canonical::ToolCall is wrong here —
          # its arguments member is Hash-only (O03a) and the accumulator reads the
          # fragment by symbol keys.
          def build_tool_call_delta_chunk(first_call, request_id, stop_reason: nil, usage: nil)
            function = first_call.fetch('function', {})
            Canonical::Chunk.tool_call_delta(
              tool_call: {
                id: first_call['id'],
                name: function['name'],
                arguments: function['arguments'].to_s,
                index: first_call['index']
              },
              request_id: request_id,
              block_index: first_call['index'],
              stop_reason: stop_reason, usage: usage
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
          private

          def coerce_chunk_input(raw)
            return nil if raw.nil?
            return nil if raw.is_a?(String) && (raw == '[DONE]' || raw.strip.empty?)
            return raw if raw.is_a?(Hash)

            Legion::JSON.load(raw)
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
              usage: data['usage'] ? canonical_usage(data['usage']) : nil,
              stop_reason: map_stop_reason(finish_reason)
            )
          end

          def parse_delta_content(delta, request_id, finish_reason, data)
            stop_reason = finish_reason ? map_stop_reason(finish_reason) : nil
            usage = finish_reason && data['usage'] ? canonical_usage(data['usage']) : nil
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

          # V10: canonical-shaped input is an EXPLICIT conformance edge
          # (the kit's shared examples feed canonical fixtures through the
          # parse boundary); in production the wire is provider-shaped.
          # A malformed canonical chunk is wiring corruption — it raises,
          # it is never silently dropped (the debug-log → nil is deleted).
          def canonical_response?(wire)
            wire.key?('text') || wire['text'] || wire.key?(:stop_reason) || wire.key?('stop_reason')
          end

          def handle_canonical_chunk(data)
            Canonical::Chunk.from_hash(data)
          end

          # V9: an unknown finish_reason is a contract error, not a fact to
          # default — the most benign semantic (:end_turn) would render a
          # future provider state as a normal completion. Absence (nil)
          # stays nil (honest absence, not a fabricated end-state).
          # 'abort' is vLLM's documented in-band failure → :error.
          def stop_reason_map_additions
            { 'abort' => :error }
          end

          def map_stop_reason(raw)
            return nil if raw.nil? || raw.to_s.empty?

            mapped = stop_reason_lookup(raw)
            if mapped.nil?
              raise ArgumentError,
                    "vllm.translator: unmapped finish_reason #{raw.inspect} — " \
                    'extend stop_reason_map_additions instead of defaulting'
            end

            mapped
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

          # V16: a non-completion body is a transport/contract fault, not a
          # provider-returned error response — it fails loud (raises)
          # instead of completing the call with a successful :error
          # response the ledger would record as a success. The
          # canonical_error_response fail-open is deleted.
          def parse_response(wire)
            unless wire.is_a?(Hash)
              raise ArgumentError,
                    "vllm.parse_response: expected a Hash completion body, got #{wire.class}"
            end
            return Canonical::Response.from_hash(wire) if canonical_response?(wire)
            raise ArgumentError, 'vllm.parse_response: completion body carries no choices' \
              unless wire['choices'].is_a?(Array)

            build_canonical_response(wire)
          rescue StandardError => e
            handle_exception(e, level: :error, handled: false, operation: 'vllm.translator.parse_response')
            raise
          end

          # V10: the base streaming layer hands this boundary parsed frames
          # only (Hash, or a canonical-shaped chunk on the explicit
          # conformance edge) — an unparseable frame is a classified
          # failure upstream (M1), never a silent nil here. The dead
          # ParseError → nil fail-open is deleted.
          def parse_chunk(raw)
            data = coerce_chunk_input(raw)
            return nil if data.nil?
            return handle_canonical_chunk(data) if data['type']
            return error_chunk_from_hash(data) if data['error']

            parse_openai_chunk(data)
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
              stop_reason_map: stop_reason_map.merge(stop_reason_map_additions),
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
