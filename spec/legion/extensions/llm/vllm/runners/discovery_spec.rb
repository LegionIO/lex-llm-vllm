# frozen_string_literal: true

require 'spec_helper'

# The Actors::Every stub ships in spec_helper (before the gem load) so the
# shared discovery actor and the vLLM Actor::Discovery are already defined.
require 'legion/extensions/llm/vllm/runners/discovery'
require 'legion/extensions/llm/vllm/actors/discovery'

# vLLM discovery: ONLY the provider-owned delta is proven here. The shared
# Discovery::Pipeline behavior (claim/activation mechanics, D4 recovery,
# cadence, replace semantics, write-time lane weights, shutdown) is a shared
# contract — proven at the shared owner (lex-llm). This spec keeps:
#   * build_offering_draft — the vLLM evidence delta (capability/operation
#     evidence, context evidence);
#   * catalog_base_url / auth_token — exercised through derive_physical_id;
#   * the config-name identity rule (two names, one endpoint);
#   * D16/V3 loud discovery failures against the vLLM catalog boundary;
#   * actor periodicity (D9).
RSpec.describe Legion::Extensions::Llm::Vllm::Runners::Discovery do
  subject(:runner) { described_class }

  let(:registry) { Legion::Extensions::Llm::Inventory::Registry }

  let(:raw_instances) do
    {
      apollo: { vllm_api_base: 'http://apollo:8000', tier: :local },
      helios: { vllm_api_base: 'http://helios:8001', tier: :local, vllm_api_key: 'sk-helios' }
    }
  end

  let(:models) do
    [
      { id: 'meta-llama/Llama-3.1-8B-Instruct', max_model_len: 131_072 },
      { id: 'BAAI/bge-large-en-v1.5', type: 'embedding', max_model_len: 512 }
    ]
  end

  let(:ready_result) do
    Legion::Extensions::Llm::Inventory::ReadinessResult.new(
      ready: true, reason: 'vLLM /health returned 200', metadata: { status: 200 }
    )
  end

  def key(instance_id)
    Legion::Extensions::Llm::Inventory::Identity::InstanceKey.new(provider_family: :vllm, instance_id: instance_id)
  end

  def apollo_physical_id
    runner.derive_physical_id(instance_cfg: { vllm_api_base: 'http://apollo:8000' })
  end

  def helios_physical_id
    runner.derive_physical_id(instance_cfg: { vllm_api_base: 'http://helios:8001', vllm_api_key: 'sk-helios' })
  end

  def settings_tree
    Legion::Settings[:extensions][:llm][:vllm]
  end

  # Legion::Settings has no module-level []=, but [:extensions] returns a live
  # mutable Hash — set the vllm subtree in place.
  def configure_vllm_settings(instances)
    Legion::Settings[:extensions][:llm] = {
      vllm: { instances: instances, discovery: { interval_seconds: 300 } }
    }
  end

  before do
    registry.reset!
    runner.reset_state!

    configure_vllm_settings(raw_instances)
    allow(Legion::Extensions::Llm::Vllm).to receive(:settings).and_return(settings_tree)
    allow(runner).to receive(:fetch_raw_models).and_return(models)
    allow(runner).to receive(:check_health) { ready_result }
  end

  # ── build_offering_draft: the vLLM evidence delta ──────────────────────────

  describe '.build_offering_draft' do
    let(:instance_key) do
      Legion::Extensions::Llm::Inventory::Identity::InstanceKey.new(
        provider_family: :vllm, instance_id: 'apollo', physical_id: '10.0.0.1:8000'
      )
    end

    let(:model_data) { { id: 'gemma-4-31b-it', max_model_len: 1_010_000 } }

    def build(instance_cfg)
      runner.build_offering_draft(
        instance_cfg: instance_cfg, instance_key: instance_key,
        model_id: 'gemma-4-31b-it', model_data: model_data
      )
    end

    def build_for(instance_cfg, model_data)
      runner.build_offering_draft(
        instance_cfg: instance_cfg, instance_key: instance_key,
        model_id: model_data[:id], model_data: model_data
      )
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
      it 'stays :unknown with default_false source (thinking is a per-model chat-template fact)' do
        evidence = cap(build({ tier: :direct }), :thinking)
        expect(evidence.status).to eq(:unknown)
        expect(evidence.source).to eq(:default_false)
      end

      # V2: the enable_thinking config dial is deleted — it no longer
      # influences execution, so a config gate can no longer source the
      # evidence. The source is :default_false in every configuration.
      it 'stays :unknown with default_false source even when config sets enable_thinking' do
        evidence = cap(build({ tier: :direct, enable_thinking: true }), :thinking)
        expect(evidence.status).to eq(:unknown)
        expect(evidence.source).to eq(:default_false)
      end

      it 'stays :unknown with default_false source for a model-level gate' do
        cfg = { tier: :direct, models: { 'gemma-4-31b-it': { enable_thinking: true } } }
        evidence = cap(build(cfg), :thinking)
        expect(evidence.status).to eq(:unknown)
        expect(evidence.source).to eq(:default_false)
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

        embed_draft = build_for({ tier: :direct }, { id: 'bge-large', type: 'embedding', max_model_len: 512 })
        expect(cap(embed_draft, :embedding)).to be_supported
        expect(cap(embed_draft, :embedding).source).to eq(:provider_implementation)
      end

      it 'keeps vision :unknown without an explicit gate' do
        evidence = cap(build({ tier: :direct }), :vision)
        expect(evidence.status).to eq(:unknown)
        expect(evidence.source).to eq(:default_false)
      end

      # The model→context mapping moved from the deleted parse_list_models
      # response hook to the draft's context evidence (provider catalog).
      it 'maps max_model_len to the context evidence value' do
        draft = build_for({ tier: :direct }, { id: 'meta-llama/Llama-3.1-8B-Instruct', max_model_len: 131_072 })

        expect(draft.context_evidence.status).to eq(:known)
        expect(draft.context_evidence.value).to eq(131_072)
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

  # ── catalog_base_url / auth_token overrides, through derive_physical_id ────
  # instance_id is the operator's config NAME; physical_id is the derived
  # host:port(/ak:<digest>) (secondary, dedup/diagnostics only).

  describe 'physical id derivation (vLLM catalog + auth overrides)' do
    it 'derives host:port from the vllm_api_base key' do
      expect(apollo_physical_id).to eq('apollo:8000')
    end

    it 'derives host:port/ak:<digest> when the instance carries a vllm_api_key' do
      fingerprint = Digest::SHA256.hexdigest('sk-helios')[0, 6]
      expect(helios_physical_id).to eq("helios:8001/ak:#{fingerprint}")
    end
  end

  # Identity is the config name, so two config names sharing one endpoint stay
  # distinct instances — the physical id is dedup/diagnostics, never identity.
  describe 'two config names sharing one endpoint' do
    let(:raw_instances) do
      {
        apollo: { vllm_api_base: 'http://apollo:8000', tier: :local },
        apollo_embed: { vllm_api_base: 'http://apollo:8000', tier: :local }
      }
    end

    it 'claims both config names as distinct instances' do
      runner.refresh

      claimed = registry.snapshot.each_instance.map { |record| record.instance_key.instance_id }.sort
      expect(claimed).to eq(%w[apollo apollo_embed])
      expect(registry.snapshot.instance(instance_key: key(:apollo)).availability.state).to eq(:available)
      expect(registry.snapshot.instance(instance_key: key(:apollo_embed)).availability.state).to eq(:available)
    end

    it 'derives the same physical_id for both but keeps them independently available' do
      runner.refresh

      apollo = registry.snapshot.instance(instance_key: key(:apollo))
      apollo_embed = registry.snapshot.instance(instance_key: key(:apollo_embed))
      expect(apollo.instance_key.physical_id).to eq(apollo_embed.instance_key.physical_id)
      expect(apollo.instance_key).not_to eq(apollo_embed.instance_key)
    end
  end

  # D16: a programming error in the discovery path must fail loud —
  # swallowing it to [] publishes ZERO offerings and makes an activated
  # instance invisible to the coordinator.
  # V3: a network/runtime fetch failure is a typed CatalogFetchFailure —
  # NOT an empty catalog. The old fail-to-[] conflation let a transient
  # timeout replace a live instance's published offerings with zero.
  describe 'D16/V3 loud discovery failures' do
    let(:cfg) { { vllm_api_base: 'http://apollo:8000', tier: :local } }

    it 're-raises a programming error from offering-building' do
      allow(runner).to receive(:build_offering_draft).and_raise(NameError, 'uninitialized constant Foo')

      expect { runner.build_offerings(instance_cfg: cfg, instance_key: key(:apollo)) }
        .to raise_error(NameError)
    end

    it 'raises CatalogFetchFailure for a network error (Faraday) instead of returning []' do
      allow(runner).to receive(:fetch_raw_models).and_raise(Faraday::ConnectionFailed, 'connection refused')

      expect { runner.build_offerings(instance_cfg: cfg, instance_key: key(:apollo)) }
        .to raise_error(runner::CatalogFetchFailure, /Faraday::ConnectionFailed/)
    end

    it 'raises CatalogFetchFailure for a non-2xx catalog response' do
      # The before-block stubs fetch_raw_models to a canned catalog — restore
      # the real method so the Faraday layer (and the status check) runs.
      allow(runner).to receive(:fetch_raw_models).and_call_original
      response = Struct.new(:status, :body).new(500, '{"error": "boom"}')
      conn = instance_double(Faraday::Connection, get: response)
      allow(runner).to receive(:build_connection).and_return(conn)

      expect { runner.fetch_raw_models(instance_cfg: cfg) }
        .to raise_error(runner::CatalogFetchFailure, /HTTP 500/)
    end

    it 'keeps a published snapshot when the catalog fetch fails on an active instance' do
      runner.refresh
      expect(registry.snapshot.instance(instance_key: key(:apollo)).availability.state).to eq(:available)
      published = registry.snapshot.lanes_for(instance_key: key(:apollo))
      sequence = registry.snapshot.publication_status(instance_key: key(:apollo)).published_sequence
      publisher = runner.publisher
      replacements = []
      allow(publisher).to receive(:replace_instance_snapshot) { |**kwargs| replacements << kwargs }

      allow(runner).to receive(:fetch_raw_models).and_raise(Faraday::TimeoutError, 'timed out')
      runner.refresh

      expect(replacements).to be_empty
      expect(registry.snapshot.lanes_for(instance_key: key(:apollo))).to eq(published)
      expect(registry.snapshot.publication_status(instance_key: key(:apollo)).published_sequence)
        .to eq(sequence)
      expect(registry.snapshot.instance(instance_key: key(:apollo)).availability.state).to eq(:available)
    end

    it 'does not activate an instance when the claim-time fetch fails' do
      allow(runner).to receive(:fetch_raw_models).and_raise(Faraday::ConnectionFailed, 'connection refused')

      runner.refresh

      # Health is ready, but the instance must NOT activate from a failed
      # observation — it stays :initializing until a successful fetch.
      expect(registry.snapshot.publication_status(instance_key: key(:apollo)).state).to eq(:initializing)
      expect(registry.snapshot.instance(instance_key: key(:apollo))).to be_nil
    end

    it 'activates on the next tick once the catalog fetch succeeds again' do
      allow(runner).to receive(:fetch_raw_models).and_raise(Faraday::ConnectionFailed, 'connection refused')
      runner.refresh
      expect(registry.snapshot.publication_status(instance_key: key(:apollo)).state).to eq(:initializing)

      allow(runner).to receive(:fetch_raw_models).and_return(models)
      runner.refresh

      expect(registry.snapshot.instance(instance_key: key(:apollo)).availability.state).to eq(:available)
    end
  end

  # ── Actor periodicity (D9) ─────────────────────────────────────────────────

  describe 'actor periodicity (D9)' do
    let(:actor) { Legion::Extensions::Llm::Vllm::Actor::Discovery.new }

    it 'reads the registered discovery interval' do
      expect(actor.time).to eq(300)
    end

    it 'honors an operator-configured interval' do
      settings_tree[:discovery] = { interval_seconds: 45 }
      expect(actor.time).to eq(45)
    end

    it 'falls back to the registered default (never nil) when the interval is invalid' do
      settings_tree[:discovery] = { interval_seconds: 0 }
      expect(actor.time).to eq(300)

      settings_tree[:discovery] = { interval_seconds: nil }
      expect(actor.time).to eq(300)
    end
  end
end
