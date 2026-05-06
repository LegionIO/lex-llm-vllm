# frozen_string_literal: true

require 'legion/extensions/llm/fleet/provider_responder'
require 'legion/extensions/llm/vllm'

module Legion
  module Extensions
    module Llm
      module Vllm
        module Runners
          # Runner entrypoint for vLLM fleet request execution.
          module FleetWorker
            module_function

            def handle_fleet_request(payload, delivery: nil, properties: nil)
              Legion::Extensions::Llm::Fleet::ProviderResponder.call(
                payload: payload,
                provider_family: Vllm::PROVIDER_FAMILY,
                provider_class: Vllm::Provider,
                provider_instances: -> { Vllm.discover_instances },
                delivery: delivery,
                properties: properties
              )
            end
          end
        end
      end
    end
  end
end
