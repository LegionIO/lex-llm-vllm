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
          # Delegates to the shared ProviderResponder with exact-offering
          # registry support for SSOT v3 execution contracts.
          #
          # `include Legion::Extensions::Helpers::Lex` injects module-level
          # `log`/`handle_exception`/`settings` (the Lex self-extend hook makes
          # the module's instance methods callable on the module itself),
          # replacing the fragile module_function + extend double-wiring.
          module FleetWorker
            include Legion::Extensions::Helpers::Lex

            # The Subscription dispatch path calls
            # `runner_class.send('handle_fleet_request', **message)` where
            # `message` is the delivered envelope (symbol keys) plus AMQP
            # metadata. For non-JSON deliveries the raw payload arrives under
            # `:value`. `delivery`/`properties` are transport handles the
            # Subscription base already acks/rejects on, forwarded only when
            # a direct caller supplies them.
            def handle_fleet_request(**message)
              delivery = message[:delivery]
              properties = message[:properties]
              payload = message.key?(:value) ? message[:value] : message.except(:delivery, :properties)

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
                registry: Legion::Extensions::Llm::Inventory::Registry,
                delivery: delivery,
                properties: properties
              )
            end

            def payload_field(payload, key)
              return unless payload.respond_to?(:[])

              payload[key] || payload[key.to_s]
            rescue StandardError => e
              handle_exception(e, level: :warn, handled: true, operation: 'vllm.fleet_worker.payload_field',
                                  field: key)
              nil
            end
          end
        end
      end
    end
  end
end
