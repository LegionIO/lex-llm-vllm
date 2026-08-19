# frozen_string_literal: true

module Legion
  module Extensions
    module Llm
      module Vllm
        module Runners
          module DiscoveryRefresh
            # vLLM rebuilds fresh evidence timestamps on every catalog pass.
            # Compare the complete draft contract while excluding only that
            # non-authoritative observation telemetry.
            module OfferingComparison
              SCALAR_EVIDENCE_FIELDS = %i[
                context_evidence max_output_evidence embedding_dimensions_evidence
                model_revision_evidence tokenizer_evidence
              ].freeze

              def offerings_equivalent?(previous, current)
                offering_comparison_multiset(previous) == offering_comparison_multiset(current)
              end

              private

              def offering_comparison_multiset(offerings)
                Array(offerings).map { |draft| offering_comparison_state(draft) }.tally
              end

              def offering_comparison_state(draft)
                state = draft.to_h
                state[:operation_evidence] = comparison_evidence_map(draft.operation_evidence)
                state[:capability_evidence] = comparison_evidence_map(draft.capability_evidence)
                SCALAR_EVIDENCE_FIELDS.each do |field|
                  state[field] = comparison_evidence(draft.public_send(field))
                end
                state
              end

              def comparison_evidence_map(evidence)
                evidence.transform_values { |entry| comparison_evidence(entry) }
              end

              def comparison_evidence(evidence)
                evidence.to_h.except(:observed_at)
              end
            end
          end
        end
      end
    end
  end
end
