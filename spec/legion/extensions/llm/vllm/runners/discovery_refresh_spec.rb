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

  # Default catalog: the extension's :default template plus two configured
  # instances. Discovery handles every endpoint-bearing instance uniformly.
  # Health-sequence tests override this to a single instance so the
  # check_health queue maps 1:1 to ticks.
  let(:raw_instances) do
    {
      default: Legion::Extensions::Llm::Vllm.default_settings.dig(:instances, :default),
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

  # V8: readiness failure carries a class-name reason and error_class
  # metadata — no exception message, no endpoint.
  let(:not_ready_result) do
    Legion::Extensions::Llm::Inventory::ReadinessResult.new(
      ready: false, reason: 'vLLM /health failed (Faraday::ConnectionFailed)',
      metadata: { error_class: 'Faraday::ConnectionFailed' }
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

    it 'claims the default template along with other endpoint-bearing instances' do
      runner.refresh

      claimed = registry.snapshot.each_instance.map { |record| record.instance_key.instance_id }.sort
      expect(claimed).to eq(%w[apollo default helios])
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
      # V14: the AvailabilityFact's own vocabulary — the pre-SSOT circuit
      # dial (circuit_state/adjustment) is gone from the settings tree.
      expect(health).to include(
        state: :available, source: :startup_readiness, last_probe_outcome: :success
      )
      expect(health).not_to have_key(:circuit_state)
      expect(health).not_to have_key(:adjustment)
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

  describe 'D4 display health while recovery is pending' do
    let(:raw_instances) { { apollo: { vllm_api_base: 'http://apollo:8000', tier: :local } } }
    let(:health_results) { [not_ready_result] }

    # V14: an :initializing instance is projected as :initializing — the
    # AvailabilityFact has no half-open state, so the old half_open
    # mislabel (and its -50 adjustment) is gone.
    it 'reports the :initializing AvailabilityFact state while the instance is down (D14)' do
      runner.refresh

      health = settings_tree.dig(:instances, :apollo, :health)
      expect(health).to include(state: :initializing)
      expect(health).not_to have_key(:circuit_state)
      expect(health).not_to have_key(:adjustment)
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
      expect(settings_tree.dig(:instances, :apollo, :health)).to include(state: :unavailable)
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

  describe 'write-time lane weights on the module-runner cadence' do
    let(:raw_instances) do
      { apollo: { vllm_api_base: 'http://apollo:8000', tier: :local } }
    end
    let(:model_id) { 'test-model' }
    let(:models) { [{ id: model_id, max_model_len: 4096 }] }

    def configure_weights(provider: 100, instance: 100, model_weights: {}, tier: 100)
      tree = settings_tree
      tree[:weight] = provider
      tree[:instances][:apollo][:weight] = instance
      tree[:instances][:apollo][:models] = model_weights.transform_values { |weight| { weight: weight } }
      Legion::Settings.loader.settings[:llm] = { routing: { tier_weights: { local: tier } } }
    end

    def build_weighted_draft(id: model_id, max_model_len: 4096, instance_key: key(:apollo), instance_cfg: raw_instances[:apollo])
      Legion::Extensions::Llm::Vllm::Helpers::OfferingBuilder.new(
        instance_cfg: instance_cfg, instance_key: instance_key
      ).build(model_id: id, model_data: { id: id, max_model_len: max_model_len })
    end

    def replace_calls_for(publisher)
      calls = []
      allow(publisher).to receive(:replace_instance_snapshot).and_wrap_original do |method, **kwargs|
        calls << kwargs
        method.call(**kwargs)
      end
      calls
    end

    around do |example|
      root = Legion::Settings.loader.settings
      original_llm = root[:llm]
      example.run
    ensure
      root[:llm] = original_llm
    end

    before { configure_weights }

    it 'does not claim malformed startup weights and recovers once on the next valid pass' do
      settings_tree[:weight] = false
      publisher = runner.publisher
      callable_class = Legion::Extensions::Llm::Vllm::VllmCallable
      allow(publisher).to receive(:claim_instance).and_call_original
      allow(callable_class).to receive(:new).and_call_original

      runner.refresh

      expect(registry.snapshot.publication_status(instance_key: key(:apollo))).to be_nil
      expect(registry.snapshot.instance(instance_key: key(:apollo))).to be_nil
      expect(runner.instance_states).to be_empty
      expect(publisher).not_to have_received(:claim_instance)
      expect(callable_class).not_to have_received(:new)

      settings_tree[:weight] = 125
      runner.refresh

      expect(publisher).to have_received(:claim_instance).once
      expect(callable_class).to have_received(:new).once
      expect(registry.snapshot.publication_status(instance_key: key(:apollo)).state).to eq(:complete)
      expect(registry.snapshot.instance(instance_key: key(:apollo)).availability.state).to eq(:available)
      expect(runner.instance_states.keys).to eq(['apollo'])
    end

    it 'publishes one frozen replacement for a weight-only change on the next ordinary pass' do
      publisher = runner.publisher
      replacements = replace_calls_for(publisher)
      fetches = 0
      probes = 0
      display_writes = 0
      allow(runner).to receive(:fetch_models) do
        fetches += 1
        models
      end
      allow(runner).to receive(:check_health) do
        probes += 1
        ready_result
      end
      allow(runner).to receive(:write_instance_health).and_wrap_original do |method, state|
        display_writes += 1
        method.call(state)
      end

      runner.refresh
      settings_tree[:weight] = 125
      runner.refresh

      expect(replacements.length).to eq(1)
      expect(replacements.first[:offerings]).to be_frozen
      expect(replacements.first[:offerings].first.weight_inputs[:provider]).to eq(125)
      expect(fetches).to eq(2)
      expect(probes).to eq(2)
      expect(display_writes).to eq(3)
    end

    it 'publishes nothing when a settings change leaves the pair unchanged' do
      publisher = runner.publisher
      replacements = replace_calls_for(publisher)
      runner.refresh
      state = runner.instance_states.fetch('apollo')
      sequence = state.fetch(:sequence)

      settings_tree[:unrelated_setting] = 'changed'
      runner.refresh

      expect(replacements).to be_empty
      expect(state.fetch(:sequence)).to eq(sequence)
    end

    it 'treats only evidence observation timestamps as volatile' do
      first = build_weighted_draft
      second = build_weighted_draft

      expect(first).not_to eq(second)
      expect(runner.send(:offerings_equivalent?, [first], [second])).to be(true)
    end

    it 'ignores equivalent catalog reordering without replacing or advancing the sequence' do
      publisher = runner.publisher
      replacements = replace_calls_for(publisher)
      model_a = { id: 'model-a', max_model_len: 4096 }
      model_b = { id: 'model-b', max_model_len: 8192 }
      allow(runner).to receive(:fetch_models).and_return([model_a, model_b], [model_b, model_a])

      runner.refresh
      state = runner.instance_states.fetch('apollo')
      sequence = state.fetch(:sequence)
      runner.refresh

      expect(replacements).to be_empty
      expect(state.fetch(:sequence)).to eq(sequence)
      expect(registry.snapshot.publication_status(instance_key: key(:apollo)).published_sequence).to eq(sequence)
    end

    it 'treats duplicate-count changes as significant without mutating cache on validation failure' do
      runner.refresh
      state = runner.instance_states.fetch('apollo')
      original = state.fetch(:offerings)
      duplicate = [original.first, original.first]
      snapshot = registry.snapshot
      published = snapshot.offerings_for(instance_key: key(:apollo))
      generation = snapshot.generation
      publisher = runner.publisher
      replacements = replace_calls_for(publisher)
      allow(runner).to receive(:fetch_offerings).and_return(duplicate)

      expect do
        runner.send(
          :replace_if_changed, instance_id: 'apollo', state: state,
                               instance_cfg: raw_instances[:apollo]
        )
      end.to raise_error(
        Legion::Extensions::Llm::Inventory::Errors::ValidationError,
        'duplicate provider_native_key'
      )
      expect(replacements.length).to eq(1)
      expect(state.values_at(:sequence, :offerings)).to eq([0, original])
      expect(registry.snapshot.offerings_for(instance_key: key(:apollo))).to eq(published)
      expect(registry.snapshot.generation).to eq(generation)
      expect(registry.snapshot.publication_status(instance_key: key(:apollo)).published_sequence).to eq(0)
    end

    it 'publishes when evidence content changes' do
      publisher = runner.publisher
      replacements = replace_calls_for(publisher)
      runner.refresh
      allow(runner).to receive(:fetch_models).and_return([{ id: model_id, max_model_len: 8192 }])

      runner.refresh

      expect(replacements.length).to eq(1)
      expect(replacements.first[:offerings].first.context_evidence.value).to eq(8192)
    end

    it 'logs the dormant cycle once per disappearance on ordinary passes' do
      ghost_cfg = { vllm_api_base: 'http://ghost:8000', tier: :local, weight: 123 }
      configure_vllm_settings(ghost: ghost_cfg)
      Legion::Settings.loader.settings[:llm] = { routing: { tier_weights: { local: 100 } } }
      allow(Legion::Extensions::Llm::Vllm).to receive_messages(settings: settings_tree, discover_instances: { ghost: ghost_cfg })
      allow(runner).to receive(:update_instance)
      logger = instance_double(Logger, info: nil)
      allow(runner).to receive(:log).and_return(logger)

      runner.refresh
      runner.refresh
      ghost_key = Legion::Extensions::Llm::Inventory::Identity::InstanceKey.new(
        provider_family: :vllm, instance_id: 'ghost'
      )
      draft = build_weighted_draft(
        instance_key: ghost_key, instance_cfg: ghost_cfg
      )
      runner.send(:state_mutex).synchronize do
        runner.instance_states['ghost'] = {
          published: true, instance_key: ghost_key, offerings: [draft]
        }
      end
      runner.refresh
      runner.send(:state_mutex).synchronize { runner.instance_states.delete('ghost') }
      runner.refresh

      text = '[llm][vllm] action=dormant_weight ' \
             'weight_key=[:vllm, :instance, "ghost"] no_lane_published=true'
      expect(logger).to have_received(:info).with(text).twice
    end

    it 'keeps sequence stable through ten unchanged ordinary passes' do
      publisher = runner.publisher
      replacements = replace_calls_for(publisher)
      runner.refresh
      state = runner.instance_states.fetch('apollo')

      10.times { runner.refresh }

      expect(replacements).to be_empty
      expect(state.fetch(:sequence)).to eq(0)
    end

    it 'has no Settings lifecycle path and clears repository-local tracking on shutdown' do
      %i[on_reload reload! reset!].each do |method_name|
        allow(Legion::Settings).to receive(method_name).and_call_original
      end
      key_value = [:vllm, :instance, 'ghost']
      tracker = runner.send(:dormant_weight_tracker)
      expect(tracker.observe(configured_keys: [key_value], published_keys: [])).to eq([key_value])

      runner.refresh
      runner.remove_all_instances

      %i[on_reload reload! reset!].each do |method_name|
        expect(Legion::Settings).not_to have_received(method_name)
      end
      expect(tracker.observe(configured_keys: [key_value], published_keys: [])).to eq([key_value])
    end

    it 'serializes interleaved ordinary passes with monotonic unique publications' do
      configure_weights(model_weights: { 'model-a' => 101, 'model-b' => 102 })
      runner.refresh
      state = runner.instance_states.fetch('apollo')
      arrived = Queue.new
      release = Queue.new
      publications = []
      publication_mutex = Mutex.new
      publisher = runner.publisher
      allow(publisher).to receive(:replace_instance_snapshot).and_wrap_original do |method, **kwargs|
        publication_mutex.synchronize { publications << kwargs }
        method.call(**kwargs)
      end
      allow(runner).to receive(:fetch_offerings) do |instance_cfg:, instance_key:|
        arrived << true
        release.pop
        [build_weighted_draft(
          id: Thread.current[:model_id], instance_key: instance_key, instance_cfg: instance_cfg
        )]
      end

      threads = %w[model-a model-b].map do |id|
        Thread.new do
          Thread.current[:model_id] = id
          runner.send(
            :replace_if_changed, instance_id: 'apollo', state: state,
                                 instance_cfg: raw_instances[:apollo]
          )
        end
      end
      2.times { arrived.pop }
      2.times { release << true }
      threads.each(&:value)

      expect(publications.map { |entry| entry[:sequence] }).to eq([1, 2])
      expect(publications.map { |entry| entry[:offerings].first.base_weight }.uniq.length).to eq(2)
      expect(state.fetch(:offerings)).to eq(publications.last.fetch(:offerings))
      expect(state.fetch(:sequence)).to eq(2)
    end

    it 'leaves the cache unchanged on replace failure and retries on the next pass' do
      runner.refresh
      state = runner.instance_states.fetch('apollo')
      original = state.fetch(:offerings)
      allow(runner).to receive(:fetch_offerings).and_return(
        [build_weighted_draft(max_model_len: 8192)]
      )
      publisher = runner.publisher
      allow(publisher).to receive(:replace_instance_snapshot).and_raise('publish failed')

      expect do
        runner.send(
          :replace_if_changed, instance_id: 'apollo', state: state,
                               instance_cfg: raw_instances[:apollo]
        )
      end.to raise_error(RuntimeError, 'publish failed')
      expect(state.values_at(:sequence, :offerings)).to eq([0, original])

      allow(publisher).to receive(:replace_instance_snapshot).and_call_original
      runner.send(
        :replace_if_changed, instance_id: 'apollo', state: state,
                             instance_cfg: raw_instances[:apollo]
      )
      expect(state.fetch(:sequence)).to eq(1)
      expect(state.fetch(:offerings).first.context_evidence.value).to eq(8192)
    end

    it 'lets removal win while ordinary discovery is in flight' do
      runner.refresh
      state = runner.instance_states.fetch('apollo')
      publisher = runner.publisher
      allow(publisher).to receive(:replace_instance_snapshot).and_call_original
      arrived = Queue.new
      release = Queue.new
      allow(runner).to receive(:fetch_offerings) do
        arrived << true
        release.pop
        [build_weighted_draft(max_model_len: 8192)]
      end

      refresh = Thread.new do
        runner.send(
          :replace_if_changed, instance_id: 'apollo', state: state,
                               instance_cfg: raw_instances[:apollo]
        )
      end
      arrived.pop
      runner.send(:remove_instance_state, 'apollo')
      release << true

      expect { refresh.value }.not_to raise_error
      expect(publisher).not_to have_received(:replace_instance_snapshot)
      expect(runner.instance_states.key?('apollo')).to be(false)
    end

    it 'rebuilds current settings after draft construction but before initial activation' do
      entered = Queue.new
      release = Queue.new
      allow(runner).to receive(:check_health) do
        entered << true
        release.pop
        ready_result
      end

      activation = Thread.new do
        runner.claim_and_activate_instance(
          name: 'apollo', instance_cfg: raw_instances[:apollo]
        )
      end
      entered.pop
      settings_tree[:weight] = 175
      release << true
      activation.value

      offering = registry.snapshot.offerings_for(instance_key: key(:apollo)).first
      state = runner.instance_states.fetch('apollo')
      expect(offering.weight_inputs[:provider]).to eq(175)
      expect(state.fetch(:offerings).first.weight_inputs[:provider]).to eq(175)
    end

    it 'updates an unpublished cache without replacement or activation and keeps it dormant' do
      logger = Logger.new(File::NULL)
      allow(logger).to receive(:info).and_call_original
      allow(runner).to receive_messages(check_health: not_ready_result, log: logger)
      publisher = runner.publisher
      allow(publisher).to receive(:replace_instance_snapshot).and_call_original
      allow(publisher).to receive(:activate_instance_snapshot).and_call_original

      runner.refresh
      settings_tree[:weight] = 175
      runner.refresh
      state = runner.instance_states.fetch('apollo')

      expect(state.fetch(:published)).to be(false)
      expect(state.fetch(:offerings).first.weight_inputs[:provider]).to eq(175)
      expect(publisher).not_to have_received(:replace_instance_snapshot)
      expect(publisher).not_to have_received(:activate_instance_snapshot)
      expect(logger).to have_received(:info).with(
        '[llm][vllm] action=dormant_weight ' \
        'weight_key=[:vllm, :provider] no_lane_published=true'
      ).once
    end

    it 'does not resurrect a tracked state removed while readiness is in flight' do
      entered = Queue.new
      release = Queue.new
      allow(runner).to receive(:check_health) do
        entered << true
        release.pop
        ready_result
      end
      publisher = runner.publisher
      allow(publisher).to receive(:activate_instance_snapshot).and_call_original
      allow(runner).to receive(:write_instance_health).and_call_original

      activation = Thread.new do
        runner.claim_and_activate_instance(
          name: 'apollo', instance_cfg: raw_instances[:apollo]
        )
      end
      entered.pop
      runner.send(:remove_instance_state, 'apollo')
      release << true
      activation.value

      expect(runner.instance_states.key?('apollo')).to be(false)
      expect(registry.snapshot.publication_status(instance_key: key(:apollo))).to be_nil
      expect(publisher).not_to have_received(:activate_instance_snapshot)
      expect(runner).not_to have_received(:write_instance_health)
    end

    it 'leaves unpublished state unchanged when activation raises and permits retry' do
      publisher = runner.publisher
      attempts = 0
      allow(publisher).to receive(:activate_instance_snapshot).and_wrap_original do |method, **kwargs|
        attempts += 1
        raise 'activation failed' if attempts == 1

        method.call(**kwargs)
      end

      runner.refresh
      state = runner.instance_states.fetch('apollo')
      cached = state.fetch(:offerings)
      expect(state.values_at(:sequence, :offerings, :published)).to eq([0, cached, false])

      runner.send(
        :perform_readiness, instance_id: 'apollo', state: state,
                            offerings: runner.fetch_offerings(
                              instance_cfg: raw_instances[:apollo], instance_key: key(:apollo)
                            )
      )
      expect(state.fetch(:published)).to be(true)
      expect(state.fetch(:sequence)).to eq(0)
    end
  end

  describe 'shutdown' do
    it 'removes all instances from the registry and clears state + display health' do
      runner.refresh
      expect(runner.instance_states.size).to eq(3)

      runner.remove_all_instances

      expect(runner.instance_states.size).to eq(0)
      expect(registry.snapshot.instance(instance_key: key(:apollo))).to be_nil
      expect(registry.snapshot.instance(instance_key: key(:helios))).to be_nil
      expect(registry.snapshot.instance(instance_key: key(:default))).to be_nil
      expect(settings_tree.dig(:instances, :apollo, :health)).to be_nil
      expect(settings_tree.dig(:instances, :apollo, :capabilities)).to be_nil
      expect(settings_tree.dig(:instances, :default, :health)).to be_nil
      expect(settings_tree.dig(:instances, :default, :capabilities)).to be_nil
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
      allow_any_instance_of(Legion::Extensions::Llm::Vllm::Helpers::OfferingBuilder)
        .to receive(:build).and_raise(NameError, 'uninitialized constant Foo')

      expect { runner.fetch_offerings(instance_cfg: cfg, instance_key: key(:apollo)) }
        .to raise_error(NameError)
    end

    it 'raises CatalogFetchFailure for a network error (Faraday) instead of returning []' do
      allow(runner).to receive(:fetch_models).and_raise(Faraday::ConnectionFailed, 'connection refused')

      expect { runner.fetch_offerings(instance_cfg: cfg, instance_key: key(:apollo)) }
        .to raise_error(described_class::CatalogFetchFailure, /Faraday::ConnectionFailed/)
    end

    it 'raises CatalogFetchFailure for a non-2xx catalog response' do
      # The before-block stubs fetch_models to a canned catalog — restore
      # the real method so the Faraday layer (and the status check) runs.
      allow(runner).to receive(:fetch_models).and_call_original
      response = Struct.new(:status, :body).new(500, '{"error": "boom"}')
      conn = instance_double(Faraday::Connection, get: response)
      allow(runner).to receive(:build_catalog_connection).and_return(conn)

      expect { runner.fetch_models(instance_cfg: cfg) }
        .to raise_error(described_class::CatalogFetchFailure, /HTTP 500/)
    end

    it 'keeps a published snapshot when the catalog fetch fails on an active instance' do
      runner.refresh
      expect(registry.snapshot.instance(instance_key: key(:apollo)).availability.state).to eq(:available)
      published = registry.snapshot.offerings_for(instance_key: key(:apollo))
      sequence = registry.snapshot.publication_status(instance_key: key(:apollo)).published_sequence
      publisher = runner.publisher
      replacements = []
      allow(publisher).to receive(:replace_instance_snapshot) do |**kwargs|
        replacements << kwargs
      end

      allow(runner).to receive(:fetch_models).and_raise(Faraday::TimeoutError, 'timed out')
      runner.refresh

      expect(replacements).to be_empty
      expect(registry.snapshot.offerings_for(instance_key: key(:apollo))).to eq(published)
      expect(registry.snapshot.publication_status(instance_key: key(:apollo)).published_sequence)
        .to eq(sequence)
      expect(registry.snapshot.instance(instance_key: key(:apollo)).availability.state).to eq(:available)
    end

    it 'does not activate an empty instance when the claim-time fetch fails' do
      allow(runner).to receive(:fetch_models).and_raise(Faraday::ConnectionFailed, 'connection refused')

      runner.refresh

      # Health is ready, but the instance must NOT activate from a failed
      # observation — it stays :initializing until a successful fetch.
      expect(registry.snapshot.publication_status(instance_key: key(:apollo)).state).to eq(:initializing)
      expect(registry.snapshot.instance(instance_key: key(:apollo))).to be_nil
    end

    it 'activates on the next tick once the catalog fetch succeeds again' do
      allow(runner).to receive(:fetch_models).and_raise(Faraday::ConnectionFailed, 'connection refused')
      runner.refresh
      expect(registry.snapshot.publication_status(instance_key: key(:apollo)).state).to eq(:initializing)

      allow(runner).to receive(:fetch_models).and_return(models)
      runner.refresh

      expect(registry.snapshot.instance(instance_key: key(:apollo)).availability.state).to eq(:available)
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
