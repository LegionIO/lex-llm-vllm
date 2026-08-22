# frozen_string_literal: true

require 'legion/extensions/llm/discovery/pipeline'
require 'legion/extensions/llm/vllm/helpers/callable'
require 'legion/extensions/llm/vllm/provider'

module Legion
  module Extensions
    module Llm
      module Vllm
        module Runners
          # vLLM discovery runner: ONLY the vLLM-specific work. The generic
          # reconcile / claim / activate / probe (cadence + reactive) / replace /
          # weight-publication / health-display pipeline is mixed in from the
          # shared Discovery::Pipeline. Weight is NOT computed here — the shared
          # WeightReconciler recomputes the write-time weight from live settings
          # at publish.
          module Discovery
            extend self
            include Legion::Extensions::Llm::Discovery::Pipeline

            # ── vLLM instance-config keys ─────────────────────────────────────
            # The normalized instance config (Vllm.discover_instances) carries the
            # vLLM-specific vllm_api_base / vllm_api_key; the pipeline's
            # catalog_base_url / auth_token read the standard keys, so override to
            # the vLLM ones.

            def catalog_base_url(instance_cfg:)
              normalize_api_base(instance_cfg[:vllm_api_base] || instance_cfg[:endpoint])
            end

            def auth_token(instance_cfg:)
              token = instance_cfg[:vllm_api_key]
              token if token.is_a?(String) && !token.strip.empty?
            end

            def build_callable(instance_cfg:)
              Legion::Extensions::Llm::Vllm::Helpers::Callable.new(instance_cfg: instance_cfg, logger: log)
            end

            # Build the Inventory::OfferingDraft for one model (evidence + metadata).
            # NO weight_inputs / base_weight — those are the identity default and the
            # shared WeightReconciler recomputes them at publish.
            def build_offering_draft(instance_cfg:, instance_key:, model_id:, model_data:)
              embed_supported = Legion::Extensions::Llm::Vllm::Provider::Capabilities.embedding_model?(model_data)
              max_output = model_data[:max_output_tokens] || model_data[:max_completion_tokens]

              Legion::Extensions::Llm::Inventory::OfferingDraft.new(
                provider_native_key: model_id,
                model: model_id,
                tier: instance_cfg[:tier] || :direct,
                operation_evidence: build_operation_evidence(embed_supported: embed_supported),
                capability_evidence: build_capability_evidence(instance_cfg: instance_cfg, model_id: model_id,
                                                               embed_supported: embed_supported),
                context_evidence: build_value_evidence(model_data[:max_model_len]),
                max_output_evidence: build_value_evidence(max_output),
                embedding_dimensions_evidence: build_embedding_dims_evidence(model_data, embed_supported),
                model_revision_evidence: build_string_evidence(model_data[:revision] || model_data[:model_revision]),
                tokenizer_evidence: build_tokenizer_evidence(model_data[:tokenizer]),
                quota_domains: {},
                metadata: build_metadata(model_id: model_id, instance_id: instance_key.instance_id,
                                         model_data: model_data),
                publication_source: :provider_catalog
              )
            end

            private

            # model_id IS model_data[:id] (the pipeline's model_id_from) — the
            # caller passes both; the draft keys on the derived id.
            def build_metadata(model_id:, instance_id:, model_data:)
              meta = { raw_model: model_id, instance_id: instance_id }
              meta[:parameter_count] = model_data[:parameter_count] if model_data[:parameter_count]
              meta[:quantization] = model_data[:quantization].to_s if model_data[:quantization]
              meta
            end

            # Operation evidence is branched on the model's operation type so it is
            # authoritative about what the instance can serve: an embedding model
            # publishes chat: :unsupported (a plain chat request can never be
            # misrouted to an embedding-only instance), and vice versa.
            def build_operation_evidence(embed_supported:)
              now = Time.now.freeze
              op = lambda do |operation, status|
                Legion::Extensions::Llm::Inventory::OperationEvidence.new(
                  operation: operation, status: status,
                  source: status == :unknown ? :default_false : :provider_implementation, observed_at: now
                )
              end
              if embed_supported
                {
                  chat: op.call(:chat, :unsupported), stream_chat: op.call(:stream_chat, :unsupported),
                  embed: op.call(:embed, :supported), image: op.call(:image, :unsupported),
                  transcribe: op.call(:transcribe, :unsupported), translate: op.call(:translate, :unsupported),
                  speak: op.call(:speak, :unsupported), moderate: op.call(:moderate, :unsupported),
                  count_tokens: op.call(:count_tokens, :unsupported)
                }
              else
                {
                  chat: op.call(:chat, :supported), stream_chat: op.call(:stream_chat, :supported),
                  embed: op.call(:embed, :unsupported), image: op.call(:image, :unsupported),
                  transcribe: op.call(:transcribe, :unsupported), translate: op.call(:translate, :unsupported),
                  speak: op.call(:speak, :unsupported), moderate: op.call(:moderate, :unsupported),
                  count_tokens: op.call(:count_tokens, :unknown)
                }
              end
            end

            def build_capability_evidence(instance_cfg:, model_id:, embed_supported:)
              now = Time.now.freeze
              cap = lambda do |capability:, status:, source:|
                Legion::Extensions::Llm::Inventory::CapabilityEvidence.new(
                  capability: capability, status: status, source: source, observed_at: now
                )
              end
              result = {
                completion: cap.call(capability: :completion, status: :supported, source: :provider_implementation),
                streaming: cap.call(capability: :streaming, status: :supported, source: :provider_implementation),
                tools: build_tools_capability(instance_cfg: instance_cfg, model_id: model_id, cap: cap),
                thinking: cap.call(capability: :thinking, status: :unknown, source: :default_false)
              }
              result[:vision] = cap.call(
                capability: :vision, status: :unknown,
                source: instance_cfg.key?(:enable_vision) ? :instance_override : :default_false
              )
              if embed_supported
                result[:embedding] =
                  cap.call(capability: :embedding, status: :supported, source: :provider_implementation)
              end
              result
            end

            # Tool calling is a vLLM engine capability for every chat model, and this
            # provider's translator implements the full tool loop — support is a
            # provider-implementation fact. An explicit enable_tools: false is an
            # operator opt-out, which the evidence contract can only express as
            # unknown (override sources may never carry :supported).
            def build_tools_capability(instance_cfg:, model_id:, cap:)
              entry = explicit_config_entry(instance_cfg: instance_cfg, config_key: :enable_tools, model_id: model_id)
              if entry && entry[:value] == false
                return cap.call(capability: :tools, status: :unknown,
                                source: entry[:source])
              end

              cap.call(capability: :tools, status: :supported, source: :provider_implementation)
            end

            # Explicit gate value from the per-model config, falling back to the
            # instance-level config. Returns { value:, source: } when either level
            # sets the key (model level wins), else nil.
            def explicit_config_entry(instance_cfg:, config_key:, model_id:)
              model_cfg = instance_cfg.dig(:models, model_id.to_sym)
              if model_cfg.is_a?(Hash) && model_cfg.key?(config_key)
                return { value: model_cfg[config_key],
                         source: :model_override }
              end
              return { value: instance_cfg[config_key], source: :instance_override } if instance_cfg.key?(config_key)

              nil
            end

            def build_value_evidence(value)
              return absent_value_evidence if value.nil? || !value.is_a?(Integer) || !value.positive?

              Legion::Extensions::Llm::Inventory::ValueEvidence.new(status: :known, value: value,
                                                                    source: :provider_catalog)
            end

            def build_embedding_dims_evidence(model_data, embed_supported)
              return absent_value_evidence unless embed_supported

              dims = model_data[:embedding_dimensions]
              return absent_value_evidence unless dims.is_a?(Array) && !dims.empty? && dims.all? do |d|
                d.is_a?(Integer) && d.positive?
              end

              Legion::Extensions::Llm::Inventory::ValueEvidence.new(status: :known, value: dims.uniq.sort,
                                                                    source: :provider_catalog)
            end

            def build_string_evidence(value)
              return absent_value_evidence unless value.is_a?(String) && !value.strip.empty?

              Legion::Extensions::Llm::Inventory::ValueEvidence.new(status: :known, value: value.strip,
                                                                    source: :provider_catalog)
            end

            def build_tokenizer_evidence(tokenizer)
              return absent_value_evidence unless tokenizer.is_a?(Hash)
              unless tokenizer[:estimator].is_a?(String) && !tokenizer[:estimator].strip.empty?
                return absent_value_evidence
              end

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

            def absent_value_evidence
              @absent_value_evidence ||= Legion::Extensions::Llm::Inventory::ValueEvidence.new(status: :unknown,
                                                                                               source: :absent)
            end
          end
        end
      end
    end
  end
end
