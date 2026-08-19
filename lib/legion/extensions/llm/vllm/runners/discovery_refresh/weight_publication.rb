# frozen_string_literal: true

module Legion
  module Extensions
    module Llm
      module Vllm
        module Runners
          module DiscoveryRefresh
            # Module-runner bindings for the shared writer reconciler. The
            # existing discovery cadence remains the only execution path.
            module WeightPublication
              def reconcile_weight_snapshot(instance_id:, state:, discovered_offerings:)
                Legion::Extensions::Llm::Inventory::WeightReconciler.commit_if_changed!(
                  settings: Legion::Settings,
                  instance_id: instance_id,
                  state: state,
                  discovered_offerings: discovered_offerings,
                  mutex: state_mutex,
                  equivalent: lambda do |previous, current|
                    !instance_states[instance_id].equal?(state) ||
                      offerings_equivalent?(previous, current)
                  end,
                  replace: method(:replace_weight_snapshot)
                )
              end

              def replace_weight_snapshot(instance_id:, state:, offerings:, sequence:)
                publisher.replace_instance_snapshot(
                  instance_id: instance_id,
                  publisher_token: state.fetch(:publisher_token),
                  offerings: offerings,
                  sequence: sequence
                )
              end

              def activate_weight_snapshot(instance_id:, state:, offerings:, sequence:, probe_token:)
                publisher.activate_instance_snapshot(
                  instance_id: instance_id,
                  publisher_token: state.fetch(:publisher_token),
                  offerings: offerings,
                  sequence: sequence,
                  probe_token: probe_token
                )
              end

              def activate_tracked_state(instance_id:, state:, probe_token:)
                Legion::Extensions::Llm::Inventory::WeightReconciler.activate_tracked!(
                  settings: Legion::Settings,
                  instance_id: instance_id,
                  state_key: state.fetch(:name),
                  state: state,
                  states: instance_states,
                  mutex: state_mutex,
                  probe_token: probe_token,
                  activate: method(:activate_weight_snapshot),
                  activation_sequence: ->(tracked) { tracked.fetch(:sequence) }
                )
              end

              def observe_dormant_weights
                Legion::Extensions::Llm::Inventory::WeightReconciler.observe_dormant!(
                  settings: Legion::Settings,
                  provider_family: :vllm,
                  states: instance_states,
                  mutex: state_mutex,
                  tracker: dormant_weight_tracker,
                  dormant_logger: lambda do |key|
                    log.info(
                      "[llm][vllm] action=dormant_weight weight_key=#{key.inspect} no_lane_published=true"
                    )
                  end
                )
              end

              def state_mutex
                @state_mutex ||= Mutex.new
              end

              def dormant_weight_tracker
                @dormant_weight_tracker ||=
                  Legion::Extensions::Llm::Inventory::DormantWeightTracker.new
              end
            end
          end
        end
      end
    end
  end
end
