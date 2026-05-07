# frozen_string_literal: true

require 'legion/extensions/llm'
require 'legion/extensions/llm/vllm/provider'
require 'legion/extensions/llm/vllm/version'

module Legion
  module Extensions
    module Llm
      # Vllm provider extension namespace.
      module Vllm
        extend ::Legion::Extensions::Core if ::Legion::Extensions.const_defined?(:Core, false)
        extend Legion::Logging::Helper
        extend Legion::Extensions::Llm::AutoRegistration

        PROVIDER_FAMILY = :vllm
        DEFAULT_INSTANCE_TIER = { tier: :direct }.freeze

        def self.default_settings
          ::Legion::Extensions::Llm.provider_settings(
            family: PROVIDER_FAMILY,
            instance: {
              endpoint: 'http://localhost:8000',
              tier: :direct,
              transport: :http,
              credentials: { api_key: nil },
              enable_thinking: true,
              usage: { inference: true, embedding: true, image: true },
              limits: { concurrency: 1 },
              fleet: {
                enabled: false,
                respond_to_requests: false,
                capabilities: %i[chat stream_chat embed],
                lanes: [],
                concurrency: 1,
                queue_suffix: nil
              }
            }
          )
        end

        def self.provider_class
          Provider
        end

        def self.registry_publisher
          @registry_publisher ||= Legion::Extensions::Llm::RegistryPublisher.new(provider_family: PROVIDER_FAMILY)
        end

        def self.discover_instances
          instances = {}

          if CredentialSources.http_ok?('http://localhost:8000', path: '/health', timeout: 0.1)
            instances[:local] = {
              vllm_api_base: 'http://localhost:8000',
              tier: :local,
              capabilities: [:completion]
            }
          end

          configured = CredentialSources.setting(:extensions, :llm, :vllm, :instances)
          if configured.is_a?(Hash)
            configured.each do |name, config|
              instances[name.to_sym] = DEFAULT_INSTANCE_TIER.merge(normalize_instance_config(config))
            end
          end

          instances
        end

        def self.normalize_instance_config(config)
          normalized = config.to_h.transform_keys(&:to_sym)
          resolve_api_base_aliases(normalized)
          normalized[:tier] ||= infer_tier_from_endpoint(normalized[:vllm_api_base])
          normalized
        end

        def self.resolve_api_base_aliases(normalized)
          normalized[:vllm_api_base] ||= normalized.delete(:base_url)
          normalized[:vllm_api_base] ||= normalized.delete(:api_base)
          normalized[:vllm_api_base] ||= normalized.delete(:endpoint)
          normalized[:vllm_api_base] = normalize_api_base(normalized[:vllm_api_base]) if normalized[:vllm_api_base]
        end

        def self.normalize_api_base(url)
          url.to_s.sub(%r{/v1/?\z}, '')
        end

        def self.infer_tier_from_endpoint(url)
          return :direct if url.nil? || url.to_s.empty?

          require 'uri'
          host = URI.parse(url.to_s).host.to_s.downcase
          %w[localhost 127.0.0.1 ::1].include?(host) ? :local : :direct
        rescue URI::InvalidURIError
          :direct
        end
      end
    end
  end
end
