# frozen_string_literal: true

require 'legion/extensions/llm/inventory/evidence'
require 'legion/extensions/llm/inventory/weight_reconciler'

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
              weight_inputs = Legion::Extensions::Llm::Inventory::WeightSchema.weight_inputs(
                settings: Legion::Settings,
                instance_key: instance_key,
                provider_native_key: model_id,
                model: model_id,
                tier: tier
              )

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
                publication_source: :provider_catalog,
                weight_inputs: weight_inputs,
                base_weight: Legion::Extensions::Llm::Inventory::WeightSchema.base_weight(weight_inputs)
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

            # Operation evidence is branched on the model's operation type so
            # the evidence is AUTHORITATIVE about what the instance can serve:
            # an embedding model publishes chat: :unsupported (matching bedrock)
            # so a plain chat request can never be misrouted to an
            # embedding-only instance, and a chat model publishes embed:
            # :unsupported.
            def build_operation_evidence(embed_supported:)
              return embedding_operation_evidence if embed_supported

              chat_operation_evidence
            end

            def embedding_operation_evidence
              now = Time.now.freeze
              op = ->(operation, status) { operation_evidence(operation: operation, status: status, now: now) }
              {
                chat: op.call(:chat, :unsupported),
                stream_chat: op.call(:stream_chat, :unsupported),
                embed: op.call(:embed, :supported),
                image: op.call(:image, :unsupported),
                transcribe: op.call(:transcribe, :unsupported),
                translate: op.call(:translate, :unsupported),
                speak: op.call(:speak, :unsupported),
                moderate: op.call(:moderate, :unsupported),
                count_tokens: op.call(:count_tokens, :unsupported)
              }
            end

            def chat_operation_evidence
              now = Time.now.freeze
              op = ->(operation, status) { operation_evidence(operation: operation, status: status, now: now) }
              {
                chat: op.call(:chat, :supported),
                stream_chat: op.call(:stream_chat, :supported),
                embed: op.call(:embed, :unsupported),
                image: op.call(:image, :unsupported),
                transcribe: op.call(:transcribe, :unsupported),
                translate: op.call(:translate, :unsupported),
                speak: op.call(:speak, :unsupported),
                moderate: op.call(:moderate, :unsupported),
                count_tokens: op.call(:count_tokens, :unknown)
              }
            end

            def operation_evidence(operation:, status:, now:)
              Legion::Extensions::Llm::Inventory::OperationEvidence.new(
                operation: operation, status: status,
                source: status == :unknown ? :default_false : :provider_implementation, observed_at: now
              )
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
                tools: tools_capability_evidence(cap, model_id),
                thinking: thinking_capability_evidence(cap, model_id)
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

            # Tool calling is a vLLM engine capability for every chat model it
            # serves, and this provider's translator implements the full tool
            # loop (including interleaved parallel tool calls), so support is a
            # provider-implementation fact, not a config permission. An
            # explicit `enable_tools: false` is an operator opt-out, which the
            # evidence contract can only express as unknown (override sources
            # may never carry :supported) — that keeps tool requests off the
            # instance without a false authoritative unsupported.
            def tools_capability_evidence(cap, model_id)
              entry = explicit_config_entry(:enable_tools, model_id)
              if entry && entry[:value] == false
                return cap.call(capability: :tools, status: :unknown, source: entry[:source])
              end

              cap.call(capability: :tools, status: :supported, source: :provider_implementation)
            end

            # Thinking support is a per-model chat-template fact that the vLLM
            # model catalog does not expose, and a config permission is not
            # evidence (SSOT v3 tri-state contract), so it stays unknown in
            # every configuration.
            def thinking_capability_evidence(cap, model_id)
              entry = explicit_config_entry(:enable_thinking, model_id)
              source = entry ? entry[:source] : :default_false
              cap.call(capability: :thinking, status: :unknown, source: source)
            end

            # Explicit gate value from the per-model config, falling back to
            # the instance-level config. Returns { value:, source: } when
            # either level sets the key (model level wins), else nil.
            def explicit_config_entry(config_key, model_id)
              model_cfg = instance_cfg.dig(:models, model_id.to_sym)
              if model_cfg.is_a?(Hash) && model_cfg.key?(config_key)
                return { value: model_cfg[config_key], source: :model_override }
              end
              return { value: instance_cfg[config_key], source: :instance_override } if instance_cfg.key?(config_key)

              nil
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
