# frozen_string_literal: true

require 'legion/extensions/llm'
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
            attr_writer :registry_publisher

            def slug = 'vllm'
            def local? = false
            def configuration_options = %i[vllm_api_base vllm_api_key]
            def configuration_requirements = []
            def capabilities = Capabilities

            def registry_publisher
              @registry_publisher ||= RegistryPublisher.new
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

          def api_base
            config.vllm_api_base || 'http://localhost:8000'
          end

          def headers
            token = config.vllm_api_key
            return {} if token.nil? || token.to_s.empty?

            { 'Authorization' => "Bearer #{token}" }
          end

          def health_url = '/health'
          def version_url = '/version'
          def reset_prefix_cache_url = '/reset_prefix_cache'
          def reset_mm_cache_url = '/reset_mm_cache'
          def sleep_url = '/sleep'
          def wake_up_url = '/wake_up'

          def health
            log.info { "checking health at #{api_base}#{health_url}" }
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

          def version
            log.info { "fetching version from #{api_base}#{version_url}" }
            connection.get(version_url).body
          end

          def reset_prefix_cache(reset_running_requests: nil, reset_external: nil)
            connection.post(with_query(reset_prefix_cache_url, reset_running_requests:, reset_external:), {}).body
          end

          def reset_mm_cache
            connection.post(reset_mm_cache_url, {}).body
          end

          def sleep(level: 1)
            connection.post(with_query(sleep_url, level:), {}).body
          end

          def wake_up(tags: nil)
            query = Array(tags).map { |tag| ['tags', tag] }
            connection.post(with_query(wake_up_url, query), {}).body
          end

          private

          def render_payload(messages, tools:, temperature:, model:, stream:, schema:, thinking:, tool_prefs:) # rubocop:disable Metrics/ParameterLists
            payload = super
            payload.delete(:reasoning_effort)
            payload[:chat_template_kwargs] = { enable_thinking: true } if thinking_enabled?(thinking)
            payload
          end

          def thinking_enabled?(thinking)
            return true if thinking.is_a?(Hash) && (thinking[:enabled] != false)
            return true if thinking.respond_to?(:enabled?) && thinking.enabled?
            return vllm_thinking_setting unless thinking

            false
          end

          def vllm_thinking_setting
            return false unless defined?(Legion::Settings)

            vllm = Legion::Settings.dig(:llm, :providers, :vllm)
            vllm.is_a?(Hash) && (vllm[:enable_thinking] == true || vllm['enable_thinking'] == true)
          rescue StandardError => e
            handle_exception(e, level: :debug, handled: true, operation: 'vllm.thinking_setting')
            false
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
