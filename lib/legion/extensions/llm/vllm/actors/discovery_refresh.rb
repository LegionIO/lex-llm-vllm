# frozen_string_literal: true

begin
  require 'legion/extensions/actors/every'
rescue LoadError => e
  warn(e.message) if $VERBOSE
end

return unless defined?(Legion::Extensions::Actors::Every)

module Legion
  module Extensions
    module Llm
      module Vllm
        module Actor
          # Periodic trigger for vLLM discovery. Stateless: it fires on the
          # configured discovery interval and dispatches to
          # Runners::DiscoveryRefresh, which owns the work and holds its
          # process-local instance state.
          class DiscoveryRefresh < Legion::Extensions::Actors::Every
            include Legion::Extensions::Helpers::Lex

            def run_now?        = true
            def use_runner?     = false
            def runner_class    = 'Legion::Extensions::Llm::Vllm::Runners::DiscoveryRefresh'
            def runner_function = 'refresh'

            # Honor the registered discovery interval. A nil TimerTask interval
            # fires once and then stops, so resolve to the registered default
            # (300s) whenever the setting is missing or non-positive.
            def time
              interval = settings.dig(:discovery, :interval_seconds)&.to_i
              interval&.positive? ? interval : 300
            end

            def shutdown
              Legion::Extensions::Llm::Vllm::Runners::DiscoveryRefresh.remove_all_instances
            rescue StandardError => e
              handle_exception(e, level: :warn, operation: 'vllm.actor.discovery_refresh.shutdown')
            end
          end
        end
      end
    end
  end
end
