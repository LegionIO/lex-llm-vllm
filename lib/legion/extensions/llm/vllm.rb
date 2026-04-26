# frozen_string_literal: true

require 'legion/extensions/llm'
require 'legion/extensions/llm/vllm/provider_settings'
require 'legion/extensions/llm/vllm/version'

module Legion
  module Extensions
    module Llm
      # Vllm provider extension namespace.
      module Vllm
        extend ::Legion::Extensions::Core if ::Legion::Extensions.const_defined?(:Core, false)

        PROVIDER_FAMILY = :vllm

        def self.default_settings
          ProviderSettings.build(
            family: PROVIDER_FAMILY,
            instance: {
              endpoint: 'http://localhost:8000',
              tier: :private,
              transport: :http,
              usage: { inference: true, embedding: false },
              limits: { concurrency: 8 }
            }
          )
        end
      end
    end
  end
end
