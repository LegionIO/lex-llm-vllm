# frozen_string_literal: true

require 'legion/extensions/llm'
require 'legion/logging'
require 'uri'

module Legion
  module Extensions
    module Llm
      module Vllm
        # ── Management endpoint helpers (public) ─────────────────────────────

        # Public methods for vLLM management/admin endpoints.
        # Included into Provider to keep the class body within length limits.
        module ProviderManagementMethods
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

          private

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

          def with_query(path, positional = [], **params)
            pairs = positional + params.compact.map { |key, value| [key.to_s, value] }
            return path if pairs.empty?

            "#{path}?#{URI.encode_www_form(pairs)}"
          end
        end

        # ── Discovery + offering helpers (private) ────────────────────────────

        # Private helpers for live offering discovery and capability resolution.
        module ProviderDiscoveryHelpers
          private

          def discovery_registry_readiness(provider_health, live:)
            {
              provider: slug.to_sym,
              configured: configured?,
              ready: provider_health[:ready] == true,
              live: live,
              health: provider_health
            }
          end

          def discover_live_offerings(filters, provider_health, live:)
            readiness = discovery_registry_readiness(provider_health, live:)
            Array(list_models(live:, **filters)).filter_map do |model|
              self.class.registry_publisher.publish_models_async([model], readiness:)
              next unless model_matches_filters?(model, filters)
              next unless model_allowed?(model.id)

              log_model_discovered(model)
              offering_from_model(model, health: provider_health)
            end
          end

          def log_model_discovered(model)
            log.debug(
              "[#{slug}] instance=#{provider_instance_id} action=model_discovered " \
              "model=#{model.id} family=#{model.family}"
            )
          end

          def log_discover_complete(offerings)
            log.info(
              "[#{slug}] instance=#{provider_instance_id} action=discover_complete " \
              "model_count=#{Array(offerings).size}"
            )
          end

          def offering_from_model(model_info, health: {})
            cache_model_context(model_info)
            policy = Legion::Extensions::Llm::CapabilityPolicy.resolve(
              real: extract_real_capabilities(model_info),
              provider_catalog: {},
              probe: {},
              provider_envelope: provider_envelope_capabilities,
              provider_config: provider_capability_config,
              instance_config: instance_capability_config,
              model_config: model_capability_config(model_info.id)
            )
            build_offering(model_info, policy, model_info.context_length, health)
          end

          def cache_model_context(model_info)
            ctx = model_info.context_length
            return unless ctx

            cache_set(model_detail_cache_key(model_info.id), { context_window: ctx }, ttl: 86_400)
          rescue StandardError => e
            handle_exception(e, level: :warn, handled: true, operation: 'vllm.cache_model_detail')
          end

          def build_offering(model_info, policy, ctx, health)
            Legion::Extensions::Llm::Routing::ModelOffering.new(**offering_attrs(model_info, policy, ctx, health))
          end

          def offering_attrs(model_info, policy, ctx, health)
            {
              provider_family: :vllm,
              instance_id: provider_instance_id,
              transport: offering_transport,
              tier: offering_tier,
              model: model_info.id,
              canonical_model_alias: optional_model_attr(model_info, :name),
              model_family: optional_model_attr(model_info, :family),
              usage_type: usage_type_for(policy),
              capabilities: policy[:capabilities],
              capability_sources: policy[:sources],
              limits: { context_window: ctx,
                        max_output_tokens: optional_model_attr(model_info, :max_output_tokens) }.compact,
              health: health,
              metadata: offering_metadata_for(model_info).merge(capability_sources: policy[:sources])
            }
          end

          def usage_type_for(policy)
            policy[:capabilities].include?(:embedding) ? :embedding : :inference
          end

          def optional_model_attr(model_info, attr)
            model_info.respond_to?(attr) ? model_info.public_send(attr) : nil
          end

          def extract_real_capabilities(model_info)
            return {} unless model_info.respond_to?(:metadata)

            meta = model_info.metadata
            meta_caps = meta.is_a?(Hash) ? meta[:capabilities] : nil
            meta_caps.is_a?(Hash) ? meta_caps : {}
          end

          def provider_envelope_capabilities
            { completion: true, streaming: true }
          end

          def offering_metadata_for(model_info)
            {
              raw_model: model_info.id,
              parameter_count: model_info.respond_to?(:parameter_count) ? model_info.parameter_count : nil,
              parameter_size: model_info.respond_to?(:parameter_size) ? model_info.parameter_size : nil,
              quantization: model_info.respond_to?(:quantization) ? model_info.quantization : nil,
              size_bytes: model_info.respond_to?(:size_bytes) ? model_info.size_bytes : nil
            }.compact
          end
        end

        # ── Canonical request bridge helpers (private) ────────────────────────

        # Private helpers for converting provider call args into Canonical::Request.
        module ProviderCanonicalRequestBridge
          private

          def build_canonical_request(messages:, **opts)
            tools = opts[:tools]
            temperature = opts[:temperature]
            model      = opts[:model]
            stream     = opts[:stream]
            schema     = opts[:schema]
            thinking   = opts[:thinking]
            tool_prefs = opts[:tool_prefs]
            Canonical::Request.build(
              messages: build_canonical_messages(messages),
              system: extract_system_prompt(messages),
              tools: build_canonical_tools(tools),
              tool_choice: format_tool_choice_from_prefs(tool_prefs),
              params: build_canonical_params(temperature: temperature, schema: schema),
              thinking: build_canonical_thinking(thinking),
              stream: stream,
              metadata: { model: extract_model_id(model) }
            )
          end

          def extract_model_id(model)
            model.respond_to?(:id) ? model.id : model.to_s
          end

          # Canonical boundary: pipeline dispatch delivers Canonical::Message
          # objects; the provider-native Chat facade delivers lex-llm Message.
          # Both are object shapes this spoke converts to canonical. Plain
          # Hashes are the bypass class (the 2026-08-19 incident) — reject
          # loudly, never silently re-canonicalize.
          def build_canonical_messages(messages)
            messages.map do |msg|
              next msg if msg.is_a?(Canonical::Message)
              next Canonical::Message.from_hash(msg.to_h) if msg.is_a?(Legion::Extensions::Llm::Message)

              raise ArgumentError,
                    "vllm provider input must be Canonical::Message objects, got #{msg.class} — " \
                    'non-canonical message shapes must not cross the dispatch boundary'
            end
          end

          def build_canonical_tools(tools)
            tools.to_h.transform_values do |tool|
              if tool.is_a?(Canonical::ToolDefinition)
                tool
              else
                Canonical::ToolDefinition.from_hash(tool.respond_to?(:to_h) ? tool.to_h : tool)
              end
            end
          end

          def build_canonical_params(temperature:, schema:)
            hash = { temperature: temperature }
            hash[:response_format] = schema if schema
            Canonical::Params.from_hash(hash)
          end

          def build_canonical_thinking(thinking)
            return thinking_config_from_object(thinking) if thinking.respond_to?(:enabled?) && thinking.enabled?

            thinking_config_from_hash(thinking) if thinking.is_a?(Hash)
          end

          def thinking_config_from_object(thinking)
            Canonical::Thinking::Config.new(effort: thinking.respond_to?(:effort) ? thinking.effort : nil)
          end

          def thinking_config_from_hash(thinking)
            Canonical::Thinking::Config.new(
              effort: thinking[:effort] || thinking['effort'],
              budget: thinking[:budget] || thinking['budget']
            )
          end

          def format_tool_choice_from_prefs(tool_prefs)
            return nil unless tool_prefs

            choice = tool_prefs[:choice] || tool_prefs['choice']
            return nil unless choice
            return choice.to_sym if %w[auto none required].include?(choice.to_s)

            { name: choice.to_s }
          end

          def extract_system_prompt(messages)
            return nil unless messages.is_a?(Array) && !messages.empty?

            first = messages.first
            return nil unless first && system_message?(first)

            message_content_string(first)
          end

          def system_message?(msg)
            msg.role.to_sym == :system
          end

          def message_content_string(msg)
            content = msg.content
            content.is_a?(String) ? content : nil
          end
        end

        # ── Legacy bridge helpers (private) ──────────────────────────────────

        # Private helpers for converting Canonical responses back to legacy types.
        module ProviderLegacyBridge
          private

          def to_legacy_message(canonical, raw_body, _raw_response)
            usage = canonical.usage || {}
            Legion::Extensions::Llm::Message.new(
              role: :assistant,
              content: canonical.text,
              model_id: canonical.model,
              tool_calls: legacy_tool_calls_hash(canonical),
              thinking: legacy_thinking(canonical),
              input_tokens: optional_usage_attr(usage, :input_tokens),
              output_tokens: optional_usage_attr(usage, :output_tokens),
              reasoning_tokens: optional_usage_attr(usage, :thinking_tokens),
              raw: raw_body
            )
          end

          def legacy_thinking(canonical)
            return nil unless canonical.thinking

            Thinking.build(text: canonical.thinking.content, signature: canonical.thinking.signature)
          end

          def legacy_tool_calls_hash(canonical)
            result = {}
            canonical.tool_calls.each do |tc|
              key = (tc.name || tc.id).to_s.to_sym
              result[key] = Legion::Extensions::Llm::ToolCall.new(id: tc.id, name: tc.name, arguments: tc.arguments)
            end
            result.empty? ? nil : result
          end

          def optional_usage_attr(usage, attr)
            usage.respond_to?(attr) ? usage.public_send(attr) : nil
          end

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
              tool_calls: legacy_chunk_tool_calls(canonical),
              thinking: thinking,
              input_tokens: usage.respond_to?(:input_tokens) ? usage.input_tokens : nil,
              output_tokens: usage.respond_to?(:output_tokens) ? usage.output_tokens : nil,
              stop_reason: canonical.stop_reason,
              raw: raw_data
            )
          end

          def legacy_chunk_tool_calls(canonical)
            return nil unless canonical.type == :tool_call_delta && canonical.tool_call

            tc = canonical.tool_call
            key = (tc.id || tc.name || :fragment).to_s.to_sym
            {
              key => Legion::Extensions::Llm::ToolCall.new(
                id: tc.id,
                name: tc.name,
                arguments: tc.arguments,
                index: canonical.block_index
              )
            }
          end
        end

        # ── Render + parse helpers (private) ─────────────────────────────────

        # Private helpers for payload rendering, response parsing, and thinking.
        module ProviderRenderParseHelpers
          private

          def render_payload(messages, **)
            canonical_req = build_canonical_request(messages: messages, **)
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
            handle_exception(e, level: :warn, handled: true, operation: 'vllm.thinking_setting')
            false
          end

          def instance_thinking_enabled?
            return config.enable_thinking if config.respond_to?(:enable_thinking)

            config.respond_to?(:[]) && config[:enable_thinking] == true
          end

          def global_thinking_enabled?
            settings[:enable_thinking] == true
          end

          def parse_completion_response(response)
            body = response.body
            canonical = translator.parse_response(body)
            to_legacy_message(canonical, body, response)
          end

          def build_chunk(data)
            result = translator.parse_chunk(data)
            return nil if result.nil?

            if result.is_a?(Array)
              result.map { |c| to_legacy_chunk(c, data) }
            else
              to_legacy_chunk(result, data)
            end
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
        end

        # ── Provider class ────────────────────────────────────────────────────

        # vLLM provider implementation for the Legion::Extensions::Llm base provider contract.
        class Provider < Legion::Extensions::Llm::Provider
          include Legion::Extensions::Llm::Provider::OpenAICompatible
          include Legion::Logging::Helper
          include ProviderManagementMethods
          include ProviderDiscoveryHelpers
          include ProviderCanonicalRequestBridge
          include ProviderLegacyBridge
          include ProviderRenderParseHelpers

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
            def vision?(_model) = false
            def functions?(_model) = false
            def embeddings?(_model) = false

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

          def translator
            @translator ||= Translator.new(config: config)
          end

          def api_base
            normalize_url(config.vllm_api_base || settings.dig(:instances, :default, :endpoint))
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
            super
          end

          def readiness(live: false)
            log.info { "checking readiness live=#{live} at #{api_base}" }
            super.tap do |metadata|
              self.class.registry_publisher.publish_readiness_async(metadata) if live
            end
          end

          def list_models(live: false, **filters)
            log.info { "discovering models from #{api_base}#{models_url}" }
            super.tap do |models|
              log.info { "discovered #{models.size} model(s) from vLLM" }
            end
          end

          def discover_offerings(live: false, **filters)
            return filter_cached_offerings(Array(@cached_offerings), filters) unless live

            provider_health = health(live:)
            @cached_offerings = discover_live_offerings(filters, provider_health, live:)
            log_discover_complete(@cached_offerings)
            @cached_offerings
          rescue StandardError => e
            handle_exception(e, level: :warn, handled: true, operation: 'vllm.discover_offerings')
            []
          end
        end
      end
    end
  end
end
