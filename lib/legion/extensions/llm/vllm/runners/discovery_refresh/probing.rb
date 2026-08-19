# frozen_string_literal: true

module Legion
  module Extensions
    module Llm
      module Vllm
        module Runners
          module DiscoveryRefresh
            # Tick refresh + cadence/reactive readiness probing for the vLLM
            # discovery runner. Mixed into DiscoveryRefresh.
            module Probing
              def refresh_instance(instance_id:, instance_cfg:)
                state = state_mutex.synchronize { instance_states[instance_id] }
                return unless state

                status = publisher.snapshot.publication_status(instance_key: state[:instance_key])
                if status.state == :initializing
                  # D4: an instance that failed readiness at boot stays
                  # :initializing until a probe passes. readiness_succeeded is
                  # invalid on :initializing, so re-activation is the only path.
                  offerings = fetch_offerings(instance_cfg: instance_cfg, instance_key: state[:instance_key])
                  perform_readiness(instance_id: instance_id, state: state, offerings: offerings)
                  return
                end

                replace_if_changed(instance_id: instance_id, state: state, instance_cfg: instance_cfg)
                run_cadence_probe(instance_id: instance_id, state: state)
              end

              def replace_if_changed(instance_id:, state:, instance_cfg:)
                new_offerings = fetch_offerings(instance_cfg: instance_cfg, instance_key: state[:instance_key])
                changed = reconcile_weight_snapshot(
                  instance_id: instance_id, state: state, discovered_offerings: new_offerings
                )
                write_instance_health(state) if changed
              end

              def run_cadence_probe(instance_id:, state:)
                coordinator = state[:probe_coordinator]
                return unless coordinator.begin_probe

                probe_token = publisher.readiness_probe_started(
                  instance_id: instance_id, publisher_token: state[:publisher_token]
                )
                readiness = check_health(instance_cfg: state[:instance_cfg])
                coordinator.finish_probe
                report_probe_result(instance_id: instance_id, state: state, probe_token: probe_token,
                                    readiness: readiness)
              rescue StandardError => e
                finish_probe_safely(coordinator)
                handle_exception(e, level: :warn, operation: 'vllm.runner.discovery.cadence_probe',
                                    instance_id: instance_id)
              end

              def handle_reactive_probe(instance_id:, request:)
                state = state_mutex.synchronize { instance_states[instance_id] }
                return unless state

                coordinator = state[:probe_coordinator]
                return unless coordinator.begin_probe(request: request)

                probe_token = publisher.readiness_probe_started(
                  instance_id: instance_id, publisher_token: state[:publisher_token]
                )
                readiness = check_health(instance_cfg: state[:instance_cfg])
                coordinator.finish_probe(request: request)
                report_probe_result(instance_id: instance_id, state: state, probe_token: probe_token,
                                    readiness: readiness)
              rescue StandardError => e
                begin
                  coordinator.finish_probe(request: request)
                rescue StandardError => finish_e
                  handle_exception(finish_e, level: :warn, operation: 'vllm.runner.discovery.reactive_probe.finish',
                                             instance_id: instance_id)
                end
                handle_exception(e, level: :warn, operation: 'vllm.runner.discovery.reactive_probe',
                                    instance_id: instance_id)
              end

              def build_probe_enqueue(instance_id:)
                proc do |request:|
                  handle_reactive_probe(instance_id: instance_id, request: request)
                  true
                rescue StandardError => e
                  handle_exception(e, level: :warn, operation: 'vllm.runner.discovery.probe_enqueue',
                                      instance_id: instance_id)
                  false
                end
              end

              private

              def finish_probe_safely(coordinator, request: nil)
                coordinator.finish_probe(request: request)
              rescue StandardError => e
                handle_exception(e, level: :warn, operation: 'vllm.runner.discovery.finish_probe')
              end
            end
          end
        end
      end
    end
  end
end
