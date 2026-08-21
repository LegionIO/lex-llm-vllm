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
            #
            # V14: the projection is the AvailabilityFact's OWN vocabulary.
            # The pre-SSOT 4-key circuit shape (circuit_state/denied/
            # available/adjustment) is deleted: adjustment is a routing-dial
            # value that has no business in the live settings tree, and
            # :initializing is not :half_open (the AvailabilityFact has no
            # half-open state).
            module HealthDisplay
              def write_instance_health(state)
                instance_key = state[:instance_key]
                snapshot = publisher.snapshot
                display = display_fact(instance_key: instance_key, snapshot: snapshot)

                instance_settings = settings.dig(:instances, state[:name].to_sym)
                return unless instance_settings.is_a?(Hash)

                instance_settings[:health] = health_hash(display)
                instance_settings[:capabilities] = union_capabilities(instance_key)
              rescue StandardError => e
                handle_exception(e, level: :warn, operation: 'vllm.runner.discovery.write_health',
                                    instance_id: state[:instance_key].instance_id)
              end

              def clear_settings_health(name:)
                instance_settings = settings.dig(:instances, name.to_sym)
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

              # The AvailabilityFact's own fields — no circuit-dial
              # projection (V14).
              def health_hash(fact)
                {
                  state: fact[:state],
                  reason: fact[:reason],
                  observed_at: fact[:observed_at]&.iso8601,
                  last_probe_outcome: fact[:last_probe_outcome],
                  source: fact[:source]
                }
              end
            end
          end
        end
      end
    end
  end
end
