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

        PROVIDER_FAMILY = :vllm

        def self.default_settings
          {
            enabled: false,
            base_url: 'localhost:8000/v1',
            default_model: nil,
            enable_thinking: true,
            model_whitelist: [],
            model_blacklist: [],
            model_cache_ttl: 300,
            tls: { enabled: false, verify: :peer },
            instances: {}
          }
        end

        def self.provider_class
          Provider
        end

        def self.registry_publisher
          @registry_publisher ||= Legion::Extensions::Llm::RegistryPublisher.new(provider_family: PROVIDER_FAMILY)
        end

        Legion::Extensions::Llm::Configuration.register_provider_options(Provider.configuration_options)
      end
    end
  end
end
