# frozen_string_literal: true

require 'legion/extensions/llm'
require 'legion/extensions/llm/vllm/translator'
require 'legion/extensions/llm/vllm/provider'
require 'legion/extensions/llm/vllm/helpers/callable'
require 'legion/extensions/llm/vllm/actors/discovery'
require 'legion/extensions/llm/vllm/version'
require 'legion/logging'
require 'legion/settings'

module Legion
  module Extensions
    module Llm
      # Vllm provider extension namespace.
      module Vllm
        extend Legion::Logging::Helper
        # V13: the module-level `settings` read in discover_instances is an
        # explicit named dependency (Legion::Settings::Helper, resolving to
        # [:extensions][:llm][:vllm] from this namespace) — not a value the
        # Legion extension loader happens to inject.
        extend Legion::Settings::Helper
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
              # V2: no enable_thinking default — thinking intent is the
              # canonical request's fact; a shipped config dial is a second
              # authority and a publication/execution contradiction.
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

        def self.discover_instances
          instances = {}
          configured = settings[:instances]
          if configured.is_a?(Hash)
            configured.each do |name, config|
              normalized = normalize_instance_config(config)

              # enabled: false is a skip, not a claimable instance: the shared
              # Discovery::Pipeline reads this method as the single claimable
              # source and would otherwise claim + publish a disabled instance
              # as a live lane (an operator's enabled: false is user-space intent).
              next if normalized[:enabled] == false

              next if normalized[:vllm_api_base].to_s.strip.empty?

              instances[name.to_sym] = DEFAULT_INSTANCE_TIER.merge(normalized)
            end
          end
          log.debug { "discovered #{instances.size} vLLM instance(s): #{instances.keys.join(', ')}" }
          instances
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
