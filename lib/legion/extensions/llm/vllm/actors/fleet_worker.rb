# frozen_string_literal: true

begin
  require 'legion/extensions/actors/subscription'
rescue LoadError => e
  warn(e.message) if $VERBOSE
end

return unless defined?(Legion::Extensions::Actors::Subscription)

require 'legion/extensions/llm/vllm'
require 'legion/extensions/llm/vllm/runners/fleet_worker'
require 'legion/extensions/llm/fleet/provider_responder'
require 'legion/logging'

module Legion
  module Extensions
    module Llm
      module Vllm
        module Actor
          # Subscription actor for vLLM fleet request consumption.
          #
          # `runner_class` resolves to the concrete runner MODULE (not a
          # String) because the Subscription dispatch path with
          # `use_runner? = false` calls `runner_class.send(fn, **message)`
          # directly — a String cannot be `send`-ed. The runner's
          # `handle_fleet_request(**message)` accepts the delivered envelope as
          # keyword arguments.
          class FleetWorker < Legion::Extensions::Actors::Subscription
            include Legion::Extensions::Helpers::Lex

            def runner_class
              Legion::Extensions::Llm::Vllm::Runners::FleetWorker
            end

            def runner_function
              'handle_fleet_request'
            end

            def use_runner?
              false
            end

            def enabled?
              instances = Vllm.discover_instances
              enabled = Legion::Extensions::Llm::Fleet::ProviderResponder.enabled_for?(instances)
              log.debug { "vLLM fleet worker enablement: enabled=#{enabled}, instance_count=#{instances.size}" }
              enabled
            rescue StandardError => e
              handle_exception(e, level: :warn, handled: true, operation: 'vllm.fleet_worker.enabled')
              false
            end
          end
        end
      end
    end
  end
end
