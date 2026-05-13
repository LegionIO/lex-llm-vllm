# frozen_string_literal: true

require 'legion/extensions/llm/fleet/provider_responder'
require 'legion/extensions/llm/vllm'
require 'legion/logging'

module Legion
  module Extensions
    module Llm
      module Vllm
        module Runners
          # Runner entrypoint for vLLM fleet request execution.
          module FleetWorker
            include Legion::Logging::Helper
            extend Legion::Logging::Helper

            module_function

            def handle_fleet_request(payload, delivery: nil, properties: nil)
              log.debug do
                "handling vLLM fleet request request_id=#{payload_field(payload, :request_id).inspect} " \
                  "provider_instance=#{payload_field(payload, :provider_instance).inspect} " \
                  "operation=#{payload_field(payload, :operation).inspect}"
              end
              Legion::Extensions::Llm::Fleet::ProviderResponder.call(
                payload: payload,
                provider_family: Vllm::PROVIDER_FAMILY,
                provider_class: Vllm::Provider,
                provider_instances: -> { Vllm.discover_instances },
                delivery: delivery,
                properties: properties
              )
            end

            def payload_field(payload, key)
              return unless payload.respond_to?(:[])

              payload[key] || payload[key.to_s]
            rescue StandardError => e
              handle_exception(e, level: :debug, handled: true, operation: 'vllm.fleet_worker.payload_field',
                                  field: key)
              nil
            end
          end
        end
      end
    end
  end
end
