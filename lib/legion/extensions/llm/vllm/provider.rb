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

        # ── Canonical request bridge helpers (private) ────────────────────────

        # Private helpers for building the vLLM Canonical::Request (the
        # provider-native dialect shape with the folded system prompt) from
        # the canonical values the base funnel delivers. Canonical
        # normalization (messages/tools/params/thinking) is the
        # Canonical::Request factory's job — this bridge only folds the
        # vLLM dialect concerns (system extraction, schema into
        # response_format, model into metadata).
        module ProviderCanonicalRequestBridge
          private

          def build_canonical_request(messages:, tools:, tool_prefs:, model:, stream:, schema:, thinking:, params:)
            Canonical::Request.build(
              messages: messages,
              system: extract_system_prompt(messages),
              tools: tools,
              tool_choice: format_tool_choice_from_prefs(tool_prefs),
              params: canonical_params_with_schema(params, schema),
              thinking: thinking,
              stream: stream,
              metadata: { model: extract_model_id(model) }
            )
          end

          def extract_model_id(model)
            model.respond_to?(:id) ? model.id : model.to_s
          end

          # The vLLM translator renders response_format from canonical params
          # (no separate schema leg on this dialect), so the edge schema folds
          # into params.response_format at the render boundary.
          def canonical_params_with_schema(params, schema)
            return params unless schema

            if params.is_a?(Canonical::Params)
              params.with(response_format: schema)
            else
              Canonical::Params.from_hash((params || {}).to_h.merge(response_format: schema))
            end
          end

          def format_tool_choice_from_prefs(tool_prefs)
            return nil unless tool_prefs

            choice = tool_prefs[:choice] || tool_prefs['choice']
            return nil unless choice
            return choice.to_sym if %w[auto none required].include?(choice.to_s)

            { name: choice.to_s }
          end

          # V15: an unsupported system-prompt shape fails at the edge
          # instead of vanishing. The vLLM dialect folds a plain-String
          # system into the request; block-shaped system content is not
          # representable on this dialect, so it is a contract error, not
          # a silently dropped authoritative request fact.
          def extract_system_prompt(messages)
            return nil unless messages.is_a?(Array) && !messages.empty?

            first = messages.first
            return nil unless first && system_message?(first)

            content = first.content
            unless content.nil? || content.is_a?(::String)
              raise ArgumentError,
                    "vllm.extract_system_prompt: system prompt must be a plain String, got #{content.class} — " \
                    'block-shaped system prompts are not supported on the vLLM dialect edge'
            end

            content
          end

          def system_message?(msg)
            msg.role.to_sym == :system
          end
        end

        # ── Render + parse helpers (private) ─────────────────────────────────

        # Private helpers for the render and parse boundaries (08 R1/R2):
        # render FROM canonical values, parse TO canonical types.
        module ProviderRenderParseHelpers
          private

          def render_payload(messages, tools:, tool_prefs:, model:, stream:, schema:, thinking:, params:)
            canonical_req = build_canonical_request(
              messages: messages, tools: tools, tool_prefs: tool_prefs, model: model,
              stream: stream, schema: schema, thinking: thinking, params: params
            )
            wire = translator.render_request(canonical_req)
            log.debug do
              "vLLM provider rendered wire payload model=#{wire[:model]} stream=#{wire[:stream]} " \
                "messages=#{(wire[:messages] || []).size} keys=#{wire.keys.join(', ')}"
            end
            wire
          end

          def parse_completion_response(response)
            translator.parse_response(response.body)
          end

          def build_chunk(data)
            translator.parse_chunk(data)
          end
        end

        # ── Provider class ────────────────────────────────────────────────────

        # vLLM provider implementation for the Legion::Extensions::Llm base provider contract.
        class Provider < Legion::Extensions::Llm::Provider
          include Legion::Extensions::Llm::Provider::OpenAICompatible
          include Legion::Logging::Helper
          include ProviderManagementMethods
          include ProviderCanonicalRequestBridge
          include ProviderRenderParseHelpers

          class << self
            def slug = 'vllm'
            def local? = false
            def default_transport = :http
            def default_tier = :direct
            def configuration_options = %i[vllm_api_base vllm_api_key]
            # V6: an explicit endpoint is what makes a vLLM instance
            # executable — construction fails without it (the base
            # ensure_configured! / configured? contract), and there is no
            # localhost or sibling-endpoint fallback anywhere.
            def configuration_requirements = %i[vllm_api_base]
            def capabilities = Capabilities
          end

          # Capability predicates for vLLM OpenAI-compatible model
          # offerings. V7: per-model derivation — the same model-type split
          # the discovery runner publishes: an embedding model does not serve
          # chat or streaming, a chat model does not serve embeds. The static
          # every-model-`streaming` claims are deleted.
          module Capabilities
            module_function

            # The one model-type predicate, shared with the discovery runner's
            # build_offering_draft. The catalog path hands string-keyed wire
            # hashes; the discovery path hands symbol-keyed JSON — both shapes
            # resolve here.
            def embedding_model?(model)
              data = model.is_a?(Hash) ? model : {}
              type = data[:type] || data['type']
              model_caps = data[:capabilities] || data['capabilities']
              type.to_s == 'embedding' ||
                (model_caps.is_a?(Array) && model_caps.include?('embedding'))
            end

            def chat?(model) = !embedding_model?(model)
            def streaming?(model) = !embedding_model?(model)
            def vision?(_model) = false
            def functions?(_model) = false
            def embeddings?(model) = embedding_model?(model)

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

          def translator
            @translator ||= Translator.new(config: config)
          end

          # V6: the instance's OWN explicit endpoint only. The gem-template
          # instances.default fallback is deleted — an instance with no
          # resolvable endpoint is unexecutable, exactly as the discovery
          # path already treats it (skip; never claim at localhost or a
          # sibling instance's endpoint).
          def api_base
            base = config.vllm_api_base
            if base.nil? || base.to_s.strip.empty?
              raise Legion::Extensions::Llm::ConfigurationError,
                    'vllm instance has no vllm_api_base — an instance without an explicit endpoint is unexecutable'
            end

            normalize_url(base)
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
        end
      end
    end
  end
end
