# frozen_string_literal: true

require 'legion/extensions/llm/inventory/publisher'
require 'legion/extensions/llm/inventory/identity'
require 'legion/extensions/llm/inventory/probe_coordinator'
require 'legion/extensions/llm/inventory/scoped_refresher'
require 'legion/extensions/llm/vllm/callable'

module Legion
  module Extensions
    module Llm
      module Vllm
        module Runners
          module DiscoveryRefresh
            # Publisher + claim/activation/readiness-commit for the vLLM
            # discovery runner. Mixed into DiscoveryRefresh.
            module ClaimActivation
              # D2: inject the legacy-coordinator compatibility bridge so the
              # SSOT registry also projects into the old Legion::LLM::Inventory
              # during the mixed-version window (no-op when it isn't loaded).
              def publisher
                @publisher ||= Legion::Extensions::Llm::Inventory::Publisher.new(
                  provider_family: :vllm,
                  compatibility_adapter: Legion::Extensions::Llm::Inventory::ScopedRefresher::LegacyCoordinatorAdapter.new(
                    provider_family: :vllm
                  )
                )
              end

              # The operator's CONFIG NAME is the instance identity
              # (InstanceKey.instance_id); the derived host:port/ak string is
              # the secondary physical_id (dedup/diagnostics, never identity).
              def claim_and_activate_instance(name:, instance_cfg:)
                instance_key = Legion::Extensions::Llm::Inventory::Identity::InstanceKey.new(
                  provider_family: :vllm, instance_id: name,
                  physical_id: derive_physical_id(instance_cfg: instance_cfg)
                )
                callable = Legion::Extensions::Llm::Vllm::VllmCallable.new(instance_cfg: instance_cfg, logger: log)
                probe_coordinator = Legion::Extensions::Llm::Inventory::ProbeCoordinator.new(
                  instance_key: instance_key, enqueue: build_probe_enqueue(instance_id: name)
                )
                publisher_token = publisher.claim_instance(
                  instance_id: name, physical_id: instance_key.physical_id,
                  callable: callable, probe_request_handle: probe_coordinator
                )

                # Store state BEFORE readiness so a failed boot probe leaves a
                # recoverable :initializing entry for the next tick (D4).
                state = {
                  name: name, instance_key: instance_key, instance_cfg: instance_cfg,
                  callable: callable, probe_coordinator: probe_coordinator,
                  publisher_token: publisher_token, sequence: 0, offerings: []
                }
                instance_states[name] = state

                offerings = fetch_offerings(instance_cfg: instance_cfg, instance_key: instance_key)
                perform_readiness(instance_id: name, state: state, offerings: offerings)
              end

              # Run a readiness probe and commit the outcome. While the instance
              # is still :initializing a passing probe re-activates it (D4);
              # once activated it reports success/failure against the
              # availability fact.
              def perform_readiness(instance_id:, state:, offerings:)
                state[:offerings] = offerings
                probe_token = publisher.readiness_probe_started(
                  instance_id: instance_id, publisher_token: state[:publisher_token]
                )
                readiness = check_health(instance_cfg: state[:instance_cfg])
                report_probe_result(instance_id: instance_id, state: state, probe_token: probe_token,
                                    readiness: readiness)
              rescue StandardError => e
                handle_exception(e, level: :warn, operation: 'vllm.runner.discovery.readiness',
                                    instance_id: instance_id)
              end

              def report_probe_result(instance_id:, state:, probe_token:, readiness:)
                status = publisher.snapshot.publication_status(instance_key: state[:instance_key])
                if readiness.ready? && status.state == :initializing
                  publisher.activate_instance_snapshot(
                    instance_id: instance_id, publisher_token: state[:publisher_token],
                    offerings: state[:offerings], sequence: state[:sequence], probe_token: probe_token
                  )
                elsif readiness.ready?
                  publisher.readiness_succeeded(instance_id: instance_id, probe_token: probe_token)
                else
                  publisher.readiness_failed(
                    instance_id: instance_id, probe_token: probe_token, reason: readiness.reason
                  )
                end
                write_instance_health(state)
              rescue StandardError => e
                handle_exception(e, level: :warn, operation: 'vllm.runner.discovery.report_probe',
                                    instance_id: instance_id)
              end
            end
          end
        end
      end
    end
  end
end
