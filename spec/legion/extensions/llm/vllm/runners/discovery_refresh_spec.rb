# frozen_string_literal: true

require 'spec_helper'

# Stub the actor runtime base class so the discovery actor loads in test
# context (the real Every requires the full LegionIO runtime).
module Legion
  module Extensions
    module Actors
      unless const_defined?(:Every, false)
        class Every
          def initialize(*_args) = nil
        end
      end
    end
  end
end

require 'legion/extensions/llm/vllm/runners/discovery_refresh'
require 'legion/extensions/llm/vllm/actors/discovery_refresh'

RSpec.describe Legion::Extensions::Llm::Vllm::Runners::DiscoveryRefresh do
  subject(:runner) { described_class }

  let(:registry) { Legion::Extensions::Llm::Inventory::Registry }

  # Default catalog: the synthetic :default template (D3 — must be skipped) plus
  # two real instances. Health-sequence tests override this to a single instance
  # so the check_health queue maps 1:1 to ticks.
  let(:raw_instances) do
    {
      default: { endpoint: 'http://localhost:8000', tier: :direct, credentials: { api_key: nil } },
      apollo: { vllm_api_base: 'http://apollo:8000', tier: :local },
      helios: { vllm_api_base: 'http://helios:8001', tier: :local, vllm_api_key: 'sk-helios' }
    }
  end

  # Health outcomes consumed one per check_health call (per instance per tick).
  # Defaults to always-ready; sequence-sensitive tests override this.
  let(:health_results) { [ready_result] }

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

  let(:not_ready_result) do
    Legion::Extensions::Llm::Inventory::ReadinessResult.new(
      ready: false, reason: 'vLLM /health connection failed: refused', metadata: { error_class: 'Faraday::ConnectionFailed' }
    )
  end

  # Identity is the operator's config NAME; the derived host:port(/ak:<digest>)
  # is the secondary physical_id (dedup/diagnostics, never identity).
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
    runner.reset_instance_states!

    configure_vllm_settings(raw_instances)
    # Vllm.discover_instances (module-level, legacy fleet path) reads settings
    # the same way the runner does — point it at the genuine tree so the real
    # D3 filtering/normalization runs.
    allow(Legion::Extensions::Llm::Vllm).to receive(:settings).and_return(settings_tree)

    allow(runner).to receive(:fetch_models).and_return(models)
    allow(runner).to receive(:check_health) { health_results.shift || ready_result }
  end

  describe 'initial claim + activation' do
    it 'claims and activates every real configured instance on the first tick' do
      runner.refresh

      expect(registry.snapshot.instance(instance_key: key(:apollo)).availability.state).to eq(:available)
      expect(registry.snapshot.publication_status(instance_key: key(:apollo)).state).to eq(:complete)
      expect(registry.snapshot.instance(instance_key: key(:helios)).availability.state).to eq(:available)
    end

    it 'does NOT claim the synthetic :default template (D3 — no phantom localhost)' do
      runner.refresh

      claimed = registry.snapshot.each_instance.map { |record| record.instance_key.instance_id }.sort
      expect(claimed).to eq(%w[apollo helios])
    end

    it 'publishes the config NAME as instance_id and the derived endpoint as the secondary physical_id' do
      runner.refresh

      apollo = registry.snapshot.instance(instance_key: key(:apollo))
      expect(apollo.instance_key.instance_id).to eq('apollo')
      expect(apollo.instance_key.physical_id).to eq(apollo_physical_id)

      helios = registry.snapshot.instance(instance_key: key(:helios))
      expect(helios.instance_key.instance_id).to eq('helios')
      expect(helios.instance_key.physical_id).to eq(helios_physical_id)
    end

    it 'writes the display health hash to settings after the commit (D14)' do
      runner.refresh

      health = settings_tree.dig(:instances, :apollo, :health)
      expect(health).to include(
        circuit_state: :closed, denied: false, available: true, adjustment: 0,
        source: :startup_readiness, last_probe_outcome: :success
      )
      expect(health[:reason]).to be_a(String)
      expect(health[:observed_at]).to be_a(String)
    end

    it 'writes the union of supported capabilities to settings after the commit (D14)' do
      runner.refresh

      caps = settings_tree.dig(:instances, :apollo, :capabilities)
      expect(caps).to include(:completion, :streaming)
    end

    it 'does not store the publisher token or coordinator in settings (D5)' do
      runner.refresh

      apollo_settings = settings_tree.dig(:instances, :apollo)
      serialized = Legion::JSON.dump(apollo_settings)
      expect(serialized).not_to include('publisher_token')
      expect(serialized).not_to include('probe_coordinator')
      expect(apollo_settings).not_to have_key(:publisher_token)
    end
  end

  describe 'D4 recovery after an initial readiness failure' do
    let(:raw_instances) { { apollo: { vllm_api_base: 'http://apollo:8000', tier: :local } } }
    let(:health_results) { [not_ready_result, not_ready_result, ready_result] }

    it 'stays :initializing while the instance is down, then re-activates when it recovers' do
      runner.refresh # tick 1: claim, readiness fails -> :initializing
      expect(registry.snapshot.publication_status(instance_key: key(:apollo)).state).to eq(:initializing)
      expect(registry.snapshot.instance(instance_key: key(:apollo))).to be_nil

      runner.refresh # tick 2: still down -> stays :initializing
      expect(registry.snapshot.publication_status(instance_key: key(:apollo)).state).to eq(:initializing)

      runner.refresh # tick 3: recovered -> re-activated via activate_instance_snapshot
      expect(registry.snapshot.instance(instance_key: key(:apollo)).availability.state).to eq(:available)
      expect(registry.snapshot.publication_status(instance_key: key(:apollo)).state).to eq(:complete)
    end
  end

  describe 'D4 half-open health while recovery is pending' do
    let(:raw_instances) { { apollo: { vllm_api_base: 'http://apollo:8000', tier: :local } } }
    let(:health_results) { [not_ready_result] }

    it 'reports :initializing health (half_open) while the instance is down (D14)' do
      runner.refresh

      health = settings_tree.dig(:instances, :apollo, :health)
      expect(health).to include(circuit_state: :half_open, available: true, adjustment: -50)
    end
  end

  describe 'D4 tick reconcile (late-removed instance)' do
    it 'removes an instance that vanished from settings on a later tick' do
      runner.refresh
      expect(registry.snapshot.instance(instance_key: key(:helios))).not_to be_nil

      # Helios is removed from the configured catalog.
      configure_vllm_settings({ apollo: raw_instances[:apollo] })
      allow(Legion::Extensions::Llm::Vllm).to receive(:settings).and_return(settings_tree)

      runner.refresh

      expect(registry.snapshot.instance(instance_key: key(:helios))).to be_nil
      expect(registry.snapshot.instance(instance_key: key(:apollo)).availability.state).to eq(:available)
      # D14: the removed instance's display health is cleared.
      expect(settings_tree.dig(:instances, :helios, :health)).to be_nil
    end
  end

  describe 'cadence probe on an activated instance' do
    let(:raw_instances) { { apollo: { vllm_api_base: 'http://apollo:8000', tier: :local } } }
    let(:health_results) { [ready_result, not_ready_result] }

    it 'marks an instance unavailable when a cadence probe fails' do
      runner.refresh # tick 1: activate
      expect(registry.snapshot.instance(instance_key: key(:apollo)).availability.state).to eq(:available)

      runner.refresh # tick 2: cadence probe now fails -> unavailable

      expect(registry.snapshot.instance(instance_key: key(:apollo)).availability.state).to eq(:unavailable)
      expect(settings_tree.dig(:instances, :apollo, :health)).to include(circuit_state: :open, available: false, adjustment: -50)
    end
  end

  describe 'endpoint move under a stable config name' do
    let(:raw_instances) { { apollo: { vllm_api_base: 'http://apollo:8000', tier: :local } } }
    let(:health_results) { [ready_result, ready_result] }

    it 're-claims the instance when its physical endpoint changes between ticks' do
      runner.refresh
      expect(registry.snapshot.instance(instance_key: key(:apollo)).instance_key.physical_id)
        .to eq(apollo_physical_id)

      # The operator moves the endpoint; the config name (identity) is unchanged.
      configure_vllm_settings({ apollo: { vllm_api_base: 'http://apollo:8001', tier: :local } })
      allow(Legion::Extensions::Llm::Vllm).to receive(:settings).and_return(settings_tree)

      runner.refresh

      apollo = registry.snapshot.instance(instance_key: key(:apollo))
      expect(apollo.instance_key.instance_id).to eq('apollo')
      expect(apollo.instance_key.physical_id).to eq('apollo:8001')
      expect(apollo.availability.state).to eq(:available)
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

  describe 'shutdown' do
    it 'removes all instances from the registry and clears state + display health' do
      runner.refresh
      expect(runner.instance_states.size).to eq(2)

      runner.remove_all_instances

      expect(runner.instance_states.size).to eq(0)
      expect(registry.snapshot.instance(instance_key: key(:apollo))).to be_nil
      expect(registry.snapshot.instance(instance_key: key(:helios))).to be_nil
      expect(settings_tree.dig(:instances, :apollo, :health)).to be_nil
      expect(settings_tree.dig(:instances, :apollo, :capabilities)).to be_nil
    end
  end

  # D16: a programming error in the discovery path must fail loud — swallowing
  # it to [] publishes ZERO offerings and makes an activated instance invisible
  # to the coordinator. Only network/runtime errors may yield an empty set.
  describe 'D16 loud programming errors' do
    let(:cfg) { { vllm_api_base: 'http://apollo:8000', tier: :local } }

    it 're-raises a programming error from offering-building instead of returning []' do
      allow_any_instance_of(Legion::Extensions::Llm::Vllm::Helpers::OfferingBuilder)
        .to receive(:build).and_raise(NameError, 'uninitialized constant Foo')

      expect { runner.fetch_offerings(instance_cfg: cfg, instance_key: key(:apollo)) }
        .to raise_error(NameError)
    end

    it 'still yields an empty set for a network error (Faraday)' do
      allow(runner).to receive(:fetch_models).and_raise(Faraday::ConnectionFailed, 'connection refused')

      expect(runner.fetch_offerings(instance_cfg: cfg, instance_key: key(:apollo))).to eq([])
    end
  end

  describe 'actor periodicity (D9)' do
    let(:actor) { Legion::Extensions::Llm::Vllm::Actor::DiscoveryRefresh.new }

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
