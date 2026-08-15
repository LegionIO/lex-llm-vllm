# frozen_string_literal: true

module Legion
  module Extensions
    module Llm
      module Vllm
        module Runners
          module DiscoveryRefresh
            # D14 display-only health + capabilities writes to settings, made
            # AFTER each registry commit. Routing authority stays in the
            # in-memory AvailabilityFact; this is visibility for the status API.
            module HealthDisplay
              def write_instance_health(state)
                instance_key = state[:instance_key]
                snapshot = publisher.snapshot
                display = display_fact(instance_key: instance_key, snapshot: snapshot)

                instance_settings = settings.dig(:instances, state[:name])
                return unless instance_settings.is_a?(Hash)

                instance_settings[:health] = health_hash(display)
                instance_settings[:capabilities] = union_capabilities(instance_key)
              rescue StandardError => e
                handle_exception(e, level: :warn, operation: 'vllm.runner.discovery.write_health',
                                    instance_id: state[:instance_key].instance_id)
              end

              def clear_settings_health(name:)
                instance_settings = settings.dig(:instances, name)
                return unless instance_settings.is_a?(Hash)

                instance_settings.delete(:health)
                instance_settings.delete(:capabilities)
              rescue StandardError => e
                handle_exception(e, level: :warn, operation: 'vllm.runner.discovery.clear_health',
                                    instance_name: name.to_s)
              end

              def union_capabilities(instance_key)
                snapshot = publisher.snapshot
                capabilities = Set.new
                snapshot.offerings_for(instance_key: instance_key).each do |offering|
                  offering.capability_evidence.each do |capability, evidence|
                    capabilities << capability if evidence.supported?
                  end
                end
                capabilities.to_a.sort
              end

              private

              # The display fact as a plain Hash: the committed AvailabilityFact
              # once activated, or a :initializing projection from the
              # publication status before the first successful readiness.
              def display_fact(instance_key:, snapshot:)
                record = snapshot.instance(instance_key: instance_key)
                if record
                  fact = record.availability
                  return {
                    state: fact.state,
                    reason: fact.reason,
                    observed_at: fact.observed_at,
                    last_probe_outcome: fact.last_probe_outcome,
                    source: fact.source
                  }
                end

                status = snapshot.publication_status(instance_key: instance_key)
                {
                  state: :initializing,
                  reason: status.last_error || 'instance initializing',
                  observed_at: status.last_probe_completed_at,
                  last_probe_outcome: status.last_probe_outcome,
                  source: :startup_readiness
                }
              end

              # Legacy 4-key health shape (circuit_state/denied/available/
              # adjustment) plus display-only reason/observed_at/last_probe_
              # outcome/source so the status API output matches pre-SSOT.
              def health_hash(fact)
                {
                  circuit_state: circuit_state_for(fact[:state]),
                  denied: false,
                  available: fact[:state] != :unavailable,
                  adjustment: fact[:state] == :available ? 0 : -50,
                  reason: fact[:reason],
                  observed_at: fact[:observed_at]&.iso8601,
                  last_probe_outcome: fact[:last_probe_outcome],
                  source: fact[:source]
                }
              end

              def circuit_state_for(state)
                case state
                when :available then :closed
                when :unavailable then :open
                else :half_open
                end
              end
            end
          end
        end
      end
    end
  end
end
