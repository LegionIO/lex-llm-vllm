# frozen_string_literal: true

require 'spec_helper'
require 'legion/extensions/llm/vllm/helpers/offering_builder'

RSpec.describe Legion::Extensions::Llm::Vllm::Helpers::OfferingBuilder do
  # instance_id is the operator's config NAME; physical_id is the derived
  # host:port (secondary, dedup/diagnostics only).
  let(:instance_key) do
    Legion::Extensions::Llm::Inventory::Identity::InstanceKey.new(
      provider_family: :vllm, instance_id: 'apollo', physical_id: '10.0.0.1:8000'
    )
  end

  let(:model_data) { { id: 'gemma-4-31b-it', max_model_len: 1_010_000 } }

  def build(instance_cfg)
    builder = described_class.new(instance_cfg: instance_cfg, instance_key: instance_key)
    builder.build(model_id: 'gemma-4-31b-it', model_data: model_data)
  end

  def build_for(instance_cfg, model_data)
    described_class.new(instance_cfg: instance_cfg, instance_key: instance_key)
                   .build(model_id: model_data[:id], model_data: model_data)
  end

  def cap(draft, capability)
    draft.capability_evidence[capability]
  end

  describe 'tools capability evidence' do
    it 'is :supported from provider-implementation evidence when no config gate is set' do
      evidence = cap(build({ tier: :direct }), :tools)
      expect(evidence.status).to eq(:supported)
      expect(evidence.source).to eq(:provider_implementation)
    end

    it 'is :supported when the instance explicitly enables tools' do
      evidence = cap(build({ tier: :direct, enable_tools: true }), :tools)
      expect(evidence.status).to eq(:supported)
      expect(evidence.source).to eq(:provider_implementation)
    end

    it 'is :unknown with instance-override source when the instance disables tools' do
      evidence = cap(build({ tier: :direct, enable_tools: false }), :tools)
      expect(evidence.status).to eq(:unknown)
      expect(evidence.source).to eq(:instance_override)
    end

    it 'is :unknown with model-override source when the model entry disables tools' do
      cfg = { tier: :direct, models: { 'gemma-4-31b-it': { enable_tools: false } } }
      evidence = cap(build(cfg), :tools)
      expect(evidence.status).to eq(:unknown)
      expect(evidence.source).to eq(:model_override)
    end

    it 'lets an explicit model-level enable override an instance-level disable' do
      cfg = {
        tier: :direct,
        enable_tools: false,
        models: { 'gemma-4-31b-it': { enable_tools: true } }
      }
      evidence = cap(build(cfg), :tools)
      expect(evidence.status).to eq(:supported)
      expect(evidence.source).to eq(:provider_implementation)
    end
  end

  describe 'thinking capability evidence' do
    it 'stays :unknown when no config gate is set (config permission is not evidence)' do
      evidence = cap(build({ tier: :direct }), :thinking)
      expect(evidence.status).to eq(:unknown)
      expect(evidence.source).to eq(:default_false)
    end

    it 'stays :unknown with override source when the instance config sets the gate' do
      evidence = cap(build({ tier: :direct, enable_thinking: true }), :thinking)
      expect(evidence.status).to eq(:unknown)
      expect(evidence.source).to eq(:instance_override)
    end

    it 'stays :unknown with model-override source for a model-level gate' do
      cfg = { tier: :direct, models: { 'gemma-4-31b-it': { enable_thinking: true } } }
      evidence = cap(build(cfg), :thinking)
      expect(evidence.status).to eq(:unknown)
      expect(evidence.source).to eq(:model_override)
    end
  end

  describe 'regression guards' do
    it 'keeps completion and streaming as provider-implementation supported' do
      draft = build({ tier: :direct })
      expect(cap(draft, :completion)).to be_supported
      expect(cap(draft, :completion).source).to eq(:provider_implementation)
      expect(cap(draft, :streaming)).to be_supported
      expect(cap(draft, :streaming).source).to eq(:provider_implementation)
    end

    it 'advertises embedding only for embedding models, sourced from the catalog' do
      embed = build({ tier: :direct })
      expect(embed.capability_evidence[:embedding]).to be_nil

      embed_draft = described_class.new(instance_cfg: { tier: :direct }, instance_key: instance_key)
                                   .build(model_id: 'bge-large', model_data: { id: 'bge-large', type: 'embedding', max_model_len: 512 })
      expect(cap(embed_draft, :embedding)).to be_supported
      expect(cap(embed_draft, :embedding).source).to eq(:provider_implementation)
    end

    it 'keeps vision :unknown without an explicit gate' do
      evidence = cap(build({ tier: :direct }), :vision)
      expect(evidence.status).to eq(:unknown)
      expect(evidence.source).to eq(:default_false)
    end
  end

  describe 'operation evidence by model type' do
    let(:chat_model) { { id: 'gemma-4-31b-it', max_model_len: 1_010_000 } }
    let(:embed_model) { { id: 'bge-large', type: 'embedding', max_model_len: 512 } }

    it 'publishes chat: :supported and embed: :unsupported for a chat model' do
      draft = build_for({ tier: :direct }, chat_model)
      expect(draft.operation_evidence[:chat].status).to eq(:supported)
      expect(draft.operation_evidence[:stream_chat].status).to eq(:supported)
      expect(draft.operation_evidence[:embed].status).to eq(:unsupported)
      expect(draft.operation_evidence[:count_tokens].status).to eq(:unknown)
    end

    it 'publishes chat: :unsupported and embed: :supported for an embedding model' do
      draft = build_for({ tier: :direct }, embed_model)
      expect(draft.operation_evidence[:chat].status).to eq(:unsupported)
      expect(draft.operation_evidence[:stream_chat].status).to eq(:unsupported)
      expect(draft.operation_evidence[:embed].status).to eq(:supported)
    end

    it 'publishes the remaining embedding-model operations as authoritative :unsupported' do
      draft = build_for({ tier: :direct }, embed_model)
      %i[chat stream_chat image transcribe translate speak moderate count_tokens].each do |op|
        expect(draft.operation_evidence[op].status).to eq(:unsupported)
        expect(draft.operation_evidence[op].source).to eq(:provider_implementation)
      end
    end
  end
end
