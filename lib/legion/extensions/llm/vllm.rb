# frozen_string_literal: true

require 'legion/extensions/llm'
require 'legion/extensions/llm/vllm/registry_event_builder'
require 'legion/extensions/llm/vllm/provider'
require 'legion/extensions/llm/vllm/registry_publisher'
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
          ::Legion::Extensions::Llm.provider_settings(
            family: PROVIDER_FAMILY,
            instance: {
              endpoint: 'http://localhost:8000',
              tier: :private,
              transport: :http,
              usage: { inference: true, embedding: true },
              limits: { concurrency: 8 }
            }
          )
        end

        def self.provider_class
          Provider
        end
      end
    end
  end
end

Legion::Extensions::Llm::Provider.register(Legion::Extensions::Llm::Vllm::PROVIDER_FAMILY,
                                           Legion::Extensions::Llm::Vllm::Provider)
