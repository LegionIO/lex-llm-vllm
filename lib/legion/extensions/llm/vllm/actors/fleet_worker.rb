# frozen_string_literal: true

begin
  require 'legion/extensions/actors/subscription'
rescue LoadError => e
  require 'legion/extensions/llm/vllm'
  unless defined?(Legion::Extensions::Actors::Subscription)
    Legion::Extensions::Llm::Vllm.handle_exception(e, level: :warn, handled: false,
                                                      operation: 'vllm.fleet_worker.load_actor_runtime')
  end
end

unless defined?(Legion::Extensions::Actors::Subscription)
  raise LoadError, 'LegionIO actor runtime is required for vLLM fleet worker'
end

require 'legion/extensions/llm/vllm'
require 'legion/extensions/llm/fleet/provider_responder'
require 'legion/logging'

module Legion
  module Extensions
    module Llm
      module Vllm
        module Actor
          # Subscription actor for vLLM fleet request consumption.
          class FleetWorker < Legion::Extensions::Actors::Subscription
            include Legion::Logging::Helper

            def runner_class
              'Legion::Extensions::Llm::Vllm::Runners::FleetWorker'
            end

            def runner_function
              'handle_fleet_request'
            end

            def use_runner?
              false
            end

            def enabled?
              Legion::Extensions::Llm::Fleet::ProviderResponder.enabled_for?(Vllm.discover_instances).tap do |enabled|
                log.debug { "vLLM fleet worker enabled=#{enabled}" }
              end
            end
          end
        end
      end
    end
  end
end
