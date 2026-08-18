# frozen_string_literal: true

require 'legion/extensions/llm'
require 'legion/extensions/llm/vllm/translator'
require 'legion/extensions/llm/vllm/provider'
require 'legion/extensions/llm/vllm/version'
require 'legion/logging'

module Legion
  module Extensions
    module Llm
      # Vllm provider extension namespace.
      module Vllm
        extend Legion::Logging::Helper
        extend Legion::Extensions::Llm::AutoRegistration

        PROVIDER_FAMILY = :vllm
        DEFAULT_INSTANCE_TIER = { tier: :direct, capabilities: {}, provider_capabilities: { streaming: true } }.freeze

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
                capabilities: %i[chat stream_chat embed]
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
          configured = settings[:instances]
          if configured.is_a?(Hash)
            configured.each do |name, config|
              normalized = normalize_instance_config(config)

              # The synthetic instances.default template (always present from
              # provider_settings) is an unconfigured phantom while it is the
              # unmodified extension default — claiming it would register and
              # health-probe a localhost target. A configured 'default'
              # (operator/auto-install values differing from the template) is
              # a real instance and stays claimable (v2 parity). Entries
              # without a resolvable endpoint are equally unclaimable.
              if unconfigured_default?(name: name, normalized: normalized)
                log.warn('[vllm][discovery] action=skip_instance instance=default reason=synthetic_default')
                next
              end

              next if normalized[:vllm_api_base].to_s.strip.empty?

              instances[name.to_sym] = DEFAULT_INSTANCE_TIER.merge(normalized)
            end
          end
          log.debug { "discovered #{instances.size} vLLM instance(s): #{instances.keys.join(', ')}" }
          instances
        end

        # The synthetic default is the extension's OWN registered instance
        # defaults (endpoint http://localhost:8000 + fleet/limits blocks),
        # deep-merged into instances.default by provider_settings. It is
        # "configured" only when the operator changed something.
        def self.unconfigured_default?(name:, normalized:)
          name.to_sym == :default && normalized == normalized_synthetic_default_instance
        end

        def self.normalized_synthetic_default_instance
          @normalized_synthetic_default_instance ||= normalize_instance_config(
            default_settings.dig(:instances, :default) || {}
          )
        end

        def self.normalize_instance_config(config)
          normalized = config.to_h.transform_keys(&:to_sym)
          resolve_api_base_aliases(normalized)
          resolve_credentials(normalized)
          normalized[:tier] ||= infer_tier_from_endpoint(normalized[:vllm_api_base])
          normalized
        end

        def self.resolve_credentials(normalized)
          creds = normalized.delete(:credentials)
          return unless creds.is_a?(Hash)

          creds = creds.transform_keys(&:to_sym)
          normalized[:vllm_api_key] ||= creds[:api_key]
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
        rescue URI::InvalidURIError => e
          handle_exception(e, level: :warn, handled: true, operation: 'vllm.infer_tier_from_endpoint')
          :direct
        end

        Legion::Extensions::Llm::Configuration.register_provider_options(Provider.configuration_options)
      end
    end
  end
end
