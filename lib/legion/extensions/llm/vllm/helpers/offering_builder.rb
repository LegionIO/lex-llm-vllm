# frozen_string_literal: true

require 'legion/extensions/llm/inventory/evidence'

module Legion
  module Extensions
    module Llm
      module Vllm
        module Helpers
          # Standalone offering builder for vLLM discovery. Constructs
          # OfferingDraft and all nested evidence structs from model catalog
          # data and instance configuration. No state, no side effects.
          class OfferingBuilder
            def initialize(instance_cfg:, instance_key:)
              @instance_cfg = instance_cfg
              @instance_key = instance_key
            end

            def build(model_id:, model_data:)
              tier = @instance_cfg[:tier] || :direct
              embed_sup = embedding_supported?(model_data)
              max_output = model_data[:max_output_tokens] || model_data[:max_completion_tokens]

              Legion::Extensions::Llm::Inventory::OfferingDraft.new(
                provider_native_key: model_id,
                model: model_id,
                tier: tier,
                operation_evidence: build_operation_evidence(embed_supported: embed_sup),
                capability_evidence: build_capability_evidence(model_id: model_id, embed_supported: embed_sup),
                context_evidence: build_value_evidence(model_data[:max_model_len]),
                max_output_evidence: build_value_evidence(max_output),
                embedding_dimensions_evidence: build_embedding_dims_evidence(model_data, embed_sup),
                model_revision_evidence: build_string_evidence(model_data[:revision] || model_data[:model_revision]),
                tokenizer_evidence: build_tokenizer_evidence(model_data[:tokenizer]),
                quota_domains: {},
                metadata: build_metadata(model_data),
                publication_source: :provider_catalog
              )
            end

            private

            attr_reader :instance_cfg, :instance_key

            def embedding_supported?(model_data)
              model_data[:type].to_s == 'embedding' ||
                (model_data[:capabilities].is_a?(Array) && model_data[:capabilities].include?('embedding'))
            end

            def build_metadata(model_data)
              meta = { raw_model: model_data[:id].to_s, instance_id: instance_key.instance_id }
              meta[:parameter_count] = model_data[:parameter_count] if model_data[:parameter_count]
              meta[:quantization] = model_data[:quantization].to_s if model_data[:quantization]
              meta
            end

            def build_operation_evidence(embed_supported:)
              now = Time.now.freeze
              src = ->(status) { status == :unknown ? :default_false : :provider_implementation }
              op = lambda do |operation:, status:|
                Legion::Extensions::Llm::Inventory::OperationEvidence.new(
                  operation: operation, status: status, source: src.call(status), observed_at: now
                )
              end
              {
                chat: op.call(operation: :chat, status: :supported),
                stream_chat: op.call(operation: :stream_chat, status: :supported),
                embed: op.call(operation: :embed, status: embed_supported ? :supported : :unsupported),
                image: op.call(operation: :image, status: :unsupported),
                transcribe: op.call(operation: :transcribe, status: :unsupported),
                translate: op.call(operation: :translate, status: :unsupported),
                speak: op.call(operation: :speak, status: :unsupported),
                moderate: op.call(operation: :moderate, status: :unsupported),
                count_tokens: op.call(operation: :count_tokens, status: :unknown)
              }
            end

            def build_capability_evidence(model_id:, embed_supported:)
              now = Time.now.freeze
              cap = lambda do |capability:, status:, source:|
                Legion::Extensions::Llm::Inventory::CapabilityEvidence.new(
                  capability: capability, status: status, source: source, observed_at: now
                )
              end
              result = {
                completion: cap.call(capability: :completion, status: :supported, source: :provider_implementation),
                streaming: cap.call(capability: :streaming, status: :supported, source: :provider_implementation),
                thinking: resolve_bool_cap(cap, :thinking, :enable_thinking, model_id),
                tools: resolve_bool_cap(cap, :tools, :enable_tools, model_id)
              }
              result[:vision] = cap.call(
                capability: :vision,
                status: :unknown,
                source: instance_cfg.key?(:enable_vision) ? :instance_override : :default_false
              )
              if embed_supported
                result[:embedding] =
                  cap.call(capability: :embedding, status: :supported,
                           source: :provider_implementation)
              end
              result
            end

            def resolve_bool_cap(cap, capability_name, config_key, model_id)
              model_cfg = instance_cfg.dig(:models, model_id.to_sym)
              if model_cfg.is_a?(Hash) && model_cfg.key?(config_key)
                return cap.call(capability: capability_name, status: :unknown, source: :model_override)
              end
              if instance_cfg.key?(config_key)
                return cap.call(capability: capability_name, status: :unknown, source: :instance_override)
              end

              cap.call(capability: capability_name, status: :unknown, source: :default_false)
            end

            def build_value_evidence(value)
              return absent if value.nil? || !value.is_a?(Integer) || !value.positive?

              Legion::Extensions::Llm::Inventory::ValueEvidence.new(status: :known, value: value,
                                                                    source: :provider_catalog)
            end

            def build_embedding_dims_evidence(model_data, embed_supported)
              return absent unless embed_supported

              dims = model_data[:embedding_dimensions]
              return absent unless dims.is_a?(Array) && !dims.empty? && dims.all? do |d|
                d.is_a?(Integer) && d.positive?
              end

              Legion::Extensions::Llm::Inventory::ValueEvidence.new(status: :known, value: dims.uniq.sort,
                                                                    source: :provider_catalog)
            end

            def build_string_evidence(value)
              return absent unless value.is_a?(String) && !value.strip.empty?

              Legion::Extensions::Llm::Inventory::ValueEvidence.new(status: :known, value: value.strip,
                                                                    source: :provider_catalog)
            end

            def build_tokenizer_evidence(tokenizer)
              return absent unless tokenizer.is_a?(Hash)
              return absent unless tokenizer[:estimator].is_a?(String) && !tokenizer[:estimator].strip.empty?

              Legion::Extensions::Llm::Inventory::ValueEvidence.new(
                status: :known,
                value: {
                  estimator: tokenizer[:estimator].strip,
                  version: (tokenizer[:version] || '1.0').to_s.strip,
                  parameters: tokenizer[:parameters].is_a?(Hash) ? tokenizer[:parameters] : {}
                },
                source: :provider_catalog
              )
            end

            def absent
              @absent ||= Legion::Extensions::Llm::Inventory::ValueEvidence.new(status: :unknown, source: :absent)
            end
          end
        end
      end
    end
  end
end
