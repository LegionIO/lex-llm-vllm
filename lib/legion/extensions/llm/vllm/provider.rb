# frozen_string_literal: true

require 'lex_llm'
require 'uri'

module Legion
  module Extensions
    module Llm
      module Vllm
        # vLLM provider implementation for the LexLLM base provider contract.
        class Provider < LexLLM::Provider
          include LexLLM::Provider::OpenAICompatible

          class << self
            def slug = 'vllm'
            def local? = true
            def configuration_options = %i[vllm_api_base vllm_api_key]
            def configuration_requirements = []
            def capabilities = Capabilities
          end

          # Capability predicates for vLLM OpenAI-compatible model offerings.
          module Capabilities
            module_function

            def chat?(_model) = true
            def streaming?(_model) = true
            def vision?(_model) = true
            def functions?(_model) = true
            def embeddings?(_model) = true
          end

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
            connection.get(health_url).body
          end

          def version
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
