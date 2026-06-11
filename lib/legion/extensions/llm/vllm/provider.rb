# frozen_string_literal: true

require 'legion/extensions/llm'
require 'legion/logging'
require 'uri'

module Legion
  module Extensions
    module Llm
      module Vllm
        # vLLM provider implementation for the Legion::Extensions::Llm base provider contract.
        class Provider < Legion::Extensions::Llm::Provider
          include Legion::Extensions::Llm::Provider::OpenAICompatible
          include Legion::Logging::Helper

          class << self
            def slug = 'vllm'
            def local? = false
            def default_transport = :http
            def default_tier = :direct
            def configuration_options = %i[vllm_api_base vllm_api_key]
            def configuration_requirements = []
            def capabilities = Capabilities

            def registry_publisher
              Vllm.registry_publisher
            end
          end

          # Capability predicates for vLLM OpenAI-compatible model offerings.
          module Capabilities
            module_function

            def chat?(_model) = true
            def streaming?(_model) = true
            def vision?(_model) = true
            def functions?(_model) = true
            def embeddings?(_model) = true

            def critical_capabilities_for(model)
              [
                ('streaming' if streaming?(model)),
                ('function_calling' if functions?(model)),
                ('vision' if vision?(model)),
                ('embeddings' if embeddings?(model))
              ].compact
            end
          end

          def stream_usage_supported? = true

          def settings
            Vllm.default_settings
          end

          # Canonical translator instance — renders requests, parses responses/chunks.
          def translator
            @translator ||= Translator.new(config: config)
          end

          def api_base
            normalize_url(config.vllm_api_base || settings[:endpoint] || 'http://localhost:8000')
          end

          def headers
            hdrs = identity_headers
            token = config.vllm_api_key
            hdrs['Authorization'] = "Bearer #{token}" unless token.nil? || token.to_s.empty?
            hdrs
          end

          def health_url = '/health'
          def version_url = '/version'
          def reset_prefix_cache_url = '/reset_prefix_cache'
          def reset_mm_cache_url = '/reset_mm_cache'
          def sleep_url = '/sleep'
          def wake_up_url = '/wake_up'

          def health(live: false)
            log.info { "checking health live=#{live} at #{api_base}#{health_url}" }
            connection.get(health_url).body
          end

          def readiness(live: false)
            log.info { "checking readiness live=#{live} at #{api_base}" }
            super.tap do |metadata|
              self.class.registry_publisher.publish_readiness_async(metadata) if live
            end
          end

          def list_models
            log.info { "discovering models from #{api_base}#{models_url}" }
            super.tap do |models|
              log.info { "discovered #{models.size} model(s) from vLLM" }
              self.class.registry_publisher.publish_models_async(models, readiness: readiness(live: false))
            end
          end

          def discover_offerings(live: false, **)
            models = if live
                       @cached_models = list_models
                     else
                       Array(@cached_models)
                     end
            offerings = models.filter_map do |model_info|
              next unless model_allowed?(model_info.id)

              offering_from_model(model_info)
            end
            log.debug { "built #{offerings.size} vLLM offering(s) live=#{live}" }
            offerings
          rescue StandardError => e
            handle_exception(e, level: :warn, handled: true, operation: 'vllm.discover_offerings')
            []
          end

          def version
            log.info { "fetching version from #{api_base}#{version_url}" }
            connection.get(version_url).body
          end

          def reset_prefix_cache(reset_running_requests: nil, reset_external: nil)
            log.debug do
              "resetting vLLM prefix cache reset_running_requests=#{reset_running_requests.inspect} " \
                "reset_external=#{reset_external.inspect}"
            end
            connection.post(with_query(reset_prefix_cache_url, reset_running_requests:, reset_external:), {}).body
          end

          def reset_mm_cache
            log.debug { 'resetting vLLM multimodal cache' }
            connection.post(reset_mm_cache_url, {}).body
          end

          def sleep(level: 1)
            log.debug { "putting vLLM worker to sleep level=#{level.inspect}" }
            connection.post(with_query(sleep_url, level:), {}).body
          end

          def wake_up(tags: nil)
            log.debug { "waking vLLM worker tags=#{Array(tags).inspect}" }
            query = Array(tags).map { |tag| ['tags', tag] }
            connection.post(with_query(wake_up_url, query), {}).body
          end

          def fetch_model_detail(model_name)
            # vLLM provides context_length via /v1/models during discovery.
            # Re-fetch from the models endpoint if we need it outside discovery.
            response = @connection.get(models_url)
            models = response.body.fetch('data', [])
            entry = models.find { |m| m['id'] == model_name.to_s }
            return nil unless entry

            ctx = entry['max_model_len']
            ctx ? { context_window: ctx } : nil
          rescue StandardError => e
            handle_exception(e, level: :warn, handled: true, operation: 'vllm.fetch_model_detail',
                                model: model_name)
            nil
          end

          private

          def offering_from_model(model_info)
            ctx = model_info.context_length
            cache_set(model_detail_cache_key(model_info.id), { context_window: ctx }, ttl: 86_400) if ctx

            Legion::Extensions::Llm::Routing::ModelOffering.new(
              provider_family: :vllm,
              instance_id: config.respond_to?(:instance_id) ? config.instance_id : :default,
              transport: offering_transport,
              tier: offering_tier,
              model: model_info.id,
              usage_type: model_info.embedding? ? :embedding : :inference,
              capabilities: model_info.capabilities.map(&:to_s),
              limits: { context_window: ctx }.compact,
              metadata: { context_length: ctx }
            )
          end

          # ── Canonical bridge: legacy provider API → Canonical::Request ──

          # rubocop:disable Metrics/ParameterLists, Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity -- bridge method can be complex
          def build_canonical_request(
            messages:, tools:, temperature:, model:, stream:, schema:, thinking:, tool_prefs:
          )
            model_id = model.respond_to?(:id) ? model.id : model.to_s

            canonical_messages = messages.filter_map do |msg|
              Canonical::Message.from_hash(msg.to_h) if msg.respond_to?(:to_h)
            end

            canonical_tools = tools.to_h.transform_values do |tool|
              if tool.is_a?(Canonical::ToolDefinition)
                tool
              else
                Canonical::ToolDefinition.from_hash(tool.respond_to?(:to_h) ? tool.to_h : tool)
              end
            end

            params_hash = { temperature: temperature }
            params_hash[:response_format] = schema if schema
            canonical_params = Canonical::Params.from_hash(params_hash)

            canonical_thinking = if thinking.respond_to?(:enabled?) && thinking.enabled?
                                   Canonical::Thinking::Config.new(
                                     effort: thinking.respond_to?(:effort) ? thinking.effort : nil
                                   )
                                 elsif thinking.is_a?(Hash)
                                   Canonical::Thinking::Config.new(
                                     effort: thinking[:effort] || thinking['effort'],
                                     budget: thinking[:budget] || thinking['budget']
                                   )
                                 end

            # Tool choice from tool_prefs
            tool_choice = format_tool_choice_from_prefs(tool_prefs)

            Canonical::Request.build(
              messages: canonical_messages,
              system: extract_system_prompt(messages),
              tools: canonical_tools,
              tool_choice: tool_choice,
              params: canonical_params,
              thinking: canonical_thinking,
              stream: stream,
              metadata: { model: model_id }
            )
          end
          # rubocop:enable Metrics/ParameterLists, Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity

          # ── Canonical bridge: Canonical→legacy Message/Chunk ──

          # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity -- verbose bridge
          def to_legacy_message(canonical, raw_body, _raw_response)
            thinking = nil
            if canonical.thinking
              thinking = Thinking.build(
                text: canonical.thinking.content,
                signature: canonical.thinking.signature
              )
            end

            tool_calls = {}
            canonical.tool_calls.each do |tc|
              key = (tc.name || tc.id).to_s.to_sym
              tool_calls[key] = Legion::Extensions::Llm::ToolCall.new(
                id: tc.id,
                name: tc.name,
                arguments: tc.arguments
              )
            end

            usage = canonical.usage || {}

            Legion::Extensions::Llm::Message.new(
              role: :assistant,
              content: canonical.text,
              model_id: canonical.model,
              tool_calls: tool_calls.empty? ? nil : tool_calls,
              thinking: thinking,
              input_tokens: usage.respond_to?(:input_tokens) ? usage.input_tokens : nil,
              output_tokens: usage.respond_to?(:output_tokens) ? usage.output_tokens : nil,
              reasoning_tokens: usage.respond_to?(:thinking_tokens) ? usage.thinking_tokens : nil,
              raw: raw_body
            )
          end
          # rubocop:enable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity

          def to_legacy_chunk(canonical, raw_data)
            usage = canonical&.usage || {}

            content = canonical.delta
            thinking = nil
            if canonical.type == :thinking_delta
              thinking = Thinking.build(text: canonical.delta)
              content = nil
            end

            Legion::Extensions::Llm::Chunk.new(
              role: :assistant,
              content: content,
              model_id: raw_data['model'],
              tool_calls: nil,
              thinking: thinking,
              input_tokens: usage.respond_to?(:input_tokens) ? usage.input_tokens : nil,
              output_tokens: usage.respond_to?(:output_tokens) ? usage.output_tokens : nil,
              raw: raw_data
            )
          end

          # ── Tool choice helpers ──

          def format_tool_choice_from_prefs(tool_prefs)
            return nil unless tool_prefs

            choice = tool_prefs[:choice] || tool_prefs['choice']
            return nil unless choice
            return choice.to_sym if %w[auto none required].include?(choice.to_s)

            { name: choice.to_s }
          end

          # rubocop:disable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity -- multibranch guard chain for system parsing
          def extract_system_prompt(messages)
            return nil unless messages.is_a?(Array)
            return nil if messages.empty?

            first = messages.first
            return nil unless first

            role = first.respond_to?(:role) ? first.role.to_sym : (first[:role] || first['role'])
            return nil unless [:system, 'system'].include?(role)

            content = first.respond_to?(:content) ? first.content : (first[:content] || first['content'])
            content.is_a?(String) ? content : nil
          end
          # rubocop:enable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity

          def render_payload(messages, tools:, temperature:, model:, stream:, schema:, thinking:, tool_prefs:) # rubocop:disable Metrics/ParameterLists
            # Build a canonical request from provider call parameters,
            # then delegate to the translator for wire-format rendering.
            canonical_req = build_canonical_request(
              messages:, tools:, temperature:, model:, stream:,
              schema:, thinking:, tool_prefs:
            )
            wire = translator.render_request(canonical_req)

            log.debug do
              "vLLM provider rendered wire payload model=#{wire[:model]} stream=#{wire[:stream]} " \
                "messages=#{(wire[:messages] || []).size} keys=#{wire.keys.join(', ')}"
            end
            wire
          end

          def thinking_enabled?(thinking)
            return true if thinking.is_a?(Hash) && (thinking[:enabled] != false)
            return true if thinking.respond_to?(:enabled?) && thinking.enabled?
            return vllm_thinking_setting unless thinking

            false
          end

          def vllm_thinking_setting
            instance_thinking_enabled? || global_thinking_enabled?
          rescue StandardError => e
            handle_exception(e, level: :debug, handled: true, operation: 'vllm.thinking_setting')
            false
          end

          def instance_thinking_enabled?
            return config.enable_thinking if config.respond_to?(:enable_thinking)

            config.respond_to?(:[]) && config[:enable_thinking] == true
          end

          def global_thinking_enabled?
            return false unless defined?(Legion::Settings)

            vllm = Legion::Settings.dig(:llm, :providers, :vllm)
            return false unless vllm.is_a?(Hash)

            vllm[:enable_thinking] == true || vllm['enable_thinking'] == true
          end

          # Override: delegate completion response parsing to the canonical translator.
          def parse_completion_response(response)
            body = response.body
            canonical = translator.parse_response(body)

            # Convert Canonical::Response back to the legacy Message/Chunk shape
            # that the Provider base class expects (backward compat with existing callers).
            to_legacy_message(canonical, body, response)
          end

          # Override: delegate SSE chunk parsing to the canonical translator.
          def build_chunk(data)
            canonical_chunk = translator.parse_chunk(data)
            return nil if canonical_chunk.nil?

            to_legacy_chunk(canonical_chunk, data)
          end

          def parse_list_models_response(response, provider, capabilities)
            response.body.fetch('data', []).map do |model|
              critical_capabilities = critical_capabilities_for(capabilities, model)
              Legion::Extensions::Llm::Model::Info.from_hash(
                id: model.fetch('id'),
                name: model['id'],
                provider: provider,
                created_at: model_created_at(model['created']),
                context_length: model['max_model_len'],
                capabilities: critical_capabilities,
                modalities: modalities_for_capabilities(critical_capabilities),
                metadata: model
              )
            end
          end

          def with_query(path, positional = [], **params)
            pairs = positional + params.compact.map { |key, value| [key.to_s, value] }
            return path if pairs.empty?

            "#{path}?#{URI.encode_www_form(pairs)}"
          end
        end
      end
    end
  end
end
