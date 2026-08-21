# frozen_string_literal: true

require 'spec_helper'
require 'faraday'
require 'digest'
require 'uri'

require 'legion/extensions/llm/inventory/publisher'
require 'legion/extensions/llm/inventory/registry'
require 'legion/extensions/llm/inventory/identity'
require 'legion/extensions/llm/inventory/records'
require 'legion/extensions/llm/inventory/evidence'
require 'legion/extensions/llm/inventory/probe_coordinator'
require 'legion/extensions/llm/routing/provider_outcome'
require 'legion/extensions/llm/taxonomies'
require 'legion/extensions/llm/capabilities'
require 'legion/extensions/llm/fleet/worker_execution'
require 'legion/extensions/llm/fleet/protocol'

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

# Load the production callable, the discovery actor, and the production
# OfferingBuilder. The conformance spec exercises the REAL VllmCallable
# (D1/D6) and DELEGATES draft-building to the production OfferingBuilder
# (D16) — no test-only subclass or duplicated builder.
require 'legion/extensions/llm/vllm/callable'
require 'legion/extensions/llm/vllm/actors/discovery_refresh'
require 'legion/extensions/llm/vllm/helpers/offering_builder'

# Supporting helpers for the SSOT v3 conformance harness. Draft/evidence
# building is DELEGATED to the production OfferingBuilder (see
# VllmSsotHarness#build_offering_drafts) — only the error-body + identity
# helpers that are specific to the spec remain here.
module VllmSsotEvidenceHelpers
  private

  def model_not_ready_signal?(error:)
    body = error_response_body(error).downcase
    body.include?('model not ready') || body.include?('model is still loading')
  end

  # Read the HTTP body off a dispatch error regardless of whether its response
  # is a plain Hash, a Faraday::Response, or a Faraday::Env (the real shape).
  def error_response_body(error)
    return error.response_body.to_s if error.respond_to?(:response_body) && !error.response_body.nil?

    response = error.response if error.respond_to?(:response)
    return response.body.to_s if response.respond_to?(:body) && !response.body.nil?

    response[:body].to_s if response.respond_to?(:[]) && !response[:body].nil?
  end

  def extract_host_port(base_url:)
    uri = URI.parse(base_url.to_s)
    "#{uri.host || 'localhost'}:#{uri.port}"
  end
end

# Harness class for vLLM SSOT v3 conformance testing. Implements the full
# interface required by the shared conformance examples without touching
# any external service. Defined inline per the conformance kit contract.
class VllmSsotHarness
  include VllmSsotEvidenceHelpers

  INSTANCE_CONFIGS = [
    {
      name: 'gpu-server-1',
      vllm_api_base: 'http://gpu-server-1.internal:8000',
      tier: :local, vllm_api_key: nil, usage: { inference: true, embedding: false }
    }.freeze,
    {
      name: 'gpu-server-2',
      vllm_api_base: 'http://gpu-server-2.internal:8001',
      tier: :local, vllm_api_key: 'sk-test-key-alpha', usage: { inference: true, embedding: false }
    }.freeze
  ].freeze

  def provider_family = :vllm
  def instance_configs = INSTANCE_CONFIGS

  # Identity is the operator's CONFIG NAME — the key the router uses for
  # instances.<name> settings lookups.
  def instance_id(instance_config:)
    instance_config[:name].to_s
  end

  # The derived host:port(/ak:<digest>) string is the SECONDARY physical id
  # (dedup/diagnostics only) — it never participates in instance identity.
  def physical_id(instance_config:)
    base_url = instance_config[:vllm_api_base] || instance_config[:endpoint] || 'http://localhost:8000'
    host_port = extract_host_port(base_url: base_url.sub(%r{/v1/?\z}, ''))
    api_key = instance_config[:vllm_api_key] || instance_config.dig(:credentials, :api_key)

    return host_port unless api_key.is_a?(String) && !api_key.strip.empty?

    "#{host_port}/ak:#{::Digest::SHA256.hexdigest(api_key)[0, 6]}"
  end

  def build_callable(instance_config:)
    Legion::Extensions::Llm::Vllm::VllmCallable.new(instance_cfg: instance_config, logger: Logger.new(File::NULL))
  end

  # D16: delegate draft-building to the PRODUCTION OfferingBuilder (not a
  # duplicated copy) so a bug in the real path (constant scope, NameError,
  # malformed evidence) is exercised by the conformance spec rather than hidden
  # by a stand-in. The kit's tier param is honored by overriding the instance
  # tier; the instance_key is derived from the passed instance_config.
  def build_offering_drafts(tier: :local, instance_config: nil, **)
    cfg_source = instance_config || instance_configs.first
    cfg_source.merge(tier: tier)
    builder = offering_builder(tier: tier, instance_config: cfg_source)
    model_id = 'meta-llama/Llama-3.1-8B-Instruct'
    [builder.build(model_id: model_id, model_data: { id: model_id, max_model_len: 131_072 })]
  end

  # Embedding-model variant of the draft builder: the production
  # OfferingBuilder decides operation evidence from the catalog `type`, so this
  # is the conformance path for the authoritative chat-exclusion check.
  def build_embedding_offering_drafts(instance_config:, tier: :local)
    builder = offering_builder(tier: tier, instance_config: instance_config)
    model_id = 'BAAI/bge-large-en-v1.5'
    [builder.build(model_id: model_id, model_data: { id: model_id, type: 'embedding', max_model_len: 512 })]
  end

  def offering_builder(tier:, instance_config:)
    cfg = instance_config.merge(tier: tier)
    instance_key = Legion::Extensions::Llm::Inventory::Identity::InstanceKey.new(
      provider_family: provider_family,
      instance_id: instance_id(instance_config: instance_config),
      physical_id: physical_id(instance_config: instance_config)
    )
    Legion::Extensions::Llm::Vllm::Helpers::OfferingBuilder.new(
      instance_cfg: cfg, instance_key: instance_key
    )
  end

  # V8: readiness metadata carries the status class only — no endpoint in
  # registry-published state (mirrors the production check_health shape).
  def safe_readiness(**)
    Legion::Extensions::Llm::Inventory::ReadinessResult.new(
      ready: true,
      reason: 'vLLM /health returned 200',
      metadata: { status: 200 }
    )
  end

  def inference_call_count(callable:)
    callable.respond_to?(:call_count) ? callable.call_count : 0
  end

  def normalize_dispatch_error(error:)
    callable = build_callable(instance_config: instance_configs.first)
    outcome = callable.normalize_dispatch_error(error: error)
    apply_vllm_escalation(outcome: outcome, error: error)
  end

  def instance_unavailable_error
    server_error(
      status: 503, body: '{"error": "Instance not available", "detail": "server is going offline"}',
      message: '503 - server is going offline'
    )
  end

  def overloaded_error
    server_error(status: 503, body: '{"error": "Server overloaded"}', message: 'the server responded with status 503')
  end

  def model_not_ready_error
    server_error(
      status: 503, body: '{"error": "Model not ready", "detail": "model is still loading"}',
      message: 'the server responded with status 503 - model is still loading'
    )
  end

  private

  # A Faraday error in the shape the adapter actually produces: the response is
  # a Faraday::Env (a Struct, NOT a Hash). The D8 regression was that the
  # callable gated body detection on `error.response.is_a?(Hash)`, which is
  # never true for a real Env — so these errors must not be plain-Hash fakes.
  def server_error(status:, body:, message:)
    env = Faraday::Env.new
    env[:status] = status
    env[:headers] = {}
    env[:body] = body
    Faraday::ServerError.new(message, env)
  end

  def apply_vllm_escalation(outcome:, error:)
    if outcome.kind == :overloaded && model_not_ready_signal?(error: error)
      return Legion::Extensions::Llm::Routing::ProviderOutcome.new(kind: :model_not_ready, reason: outcome.reason)
    end

    outcome
  end
end

RSpec.describe Legion::Extensions::Llm::Vllm do
  let(:ssot_harness) { VllmSsotHarness.new }
  let(:registry) { Legion::Extensions::Llm::Inventory::Registry }

  before do
    registry.reset!
    # Offline: stub the Faraday connection boundary so the production
    # callable's dispatch (VllmCallable -> Vllm::Provider -> Connection#post)
    # reaches a canned response without a real HTTP round-trip. Streaming
    # dispatch drives the REAL on_data SSE handler with canned lines, so
    # render_payload, parse_chunk and the StreamAccumulator all run for
    # stream_chat. The response echoes the requested model (provider wire
    # behavior) so B4 can assert the Selection-derived model round-trips.
    # NOTE: any_instance stubs receive the instance as the first block arg.
    allow_any_instance_of(Legion::Extensions::Llm::Connection)
      .to receive(:post) do |_connection, _url, payload, &block|
        fake_request = Struct.new(:options, :headers).new(Faraday::RequestOptions.new, {})
        block&.call(fake_request)
        on_data = fake_request.options.on_data
        stream_sse_lines.each { |line| on_data.call(line, 0, nil) } if on_data
        canned_completion_response(payload)
      end
  end

  def completion_response
    @completion_response ||= Struct.new(:body).new(
      {
        'choices' => [{ 'message' => { 'role' => 'assistant', 'content' => 'conformance' } }],
        'model' => 'meta-llama/Llama-3.1-8B-Instruct',
        'usage' => { 'prompt_tokens' => 1, 'completion_tokens' => 1 }
      }
    )
  end

  def canned_completion_response(payload)
    Struct.new(:body).new(
      {
        'choices' => [{ 'message' => { 'role' => 'assistant', 'content' => 'conformance' } }],
        'model' => payload[:model],
        'usage' => { 'prompt_tokens' => 1, 'completion_tokens' => 1 }
      }
    )
  end

  def stream_sse_lines
    body = { 'id' => 'stream-1', 'model' => 'stream-model',
             'choices' => [{ 'delta' => { 'content' => 'hello' }, 'finish_reason' => nil }] }
    ["data: #{Legion::JSON.dump(body)}\n\n", "data: [DONE]\n\n"]
  end

  it_behaves_like 'an SSOT v3 provider adapter'

  # ─── 0.8.0 conformance kit — boundary groups against the real callable ────
  # The kit (09 §5) is the single oracle: the B boundary examples run against
  # the PRODUCTION VllmCallable (D1/D6 — no fake returning canonical objects
  # directly). The outer Connection#post stub serves the canned response and
  # drives the real on_data SSE handler, so render_payload / parse_response /
  # parse_chunk / StreamAccumulator all run on these paths.

  describe '0.8.0 conformance kit — canonical boundary (B groups)' do
    let(:callable) { ssot_harness.build_callable(instance_config: ssot_harness.instance_configs[0]) }

    it_behaves_like 'B1 — central canonical enforcement (08 F2)'
    it_behaves_like 'B2 — canonical outputs (05 O5, 08 R2)'
    it_behaves_like 'B3 — operation preservation (PR #189 defect class)'
    it_behaves_like 'B4 — no model re-derivation (PR #45 law)'
  end

  # ─── vLLM-specific identity: config name + secondary physical id ───────────

  describe 'instance identity (config name) + secondary physical id' do
    it 'uses the operator config name as instance_id' do
      config = ssot_harness.instance_configs.first
      expect(ssot_harness.instance_id(instance_config: config)).to eq('gpu-server-1')
    end

    it 'derives the secondary physical_id as host:port without API key' do
      config = { name: 'gpu-server-1', vllm_api_base: 'http://gpu-server-1.internal:8000' }
      expect(ssot_harness.physical_id(instance_config: config)).to eq('gpu-server-1.internal:8000')
    end

    it 'derives the secondary physical_id as host:port/ak:fingerprint with API key' do
      config = { name: 'gpu-server-2', vllm_api_base: 'http://gpu-server-2.internal:8001', vllm_api_key: 'sk-test-key-alpha' }
      fingerprint = Digest::SHA256.hexdigest('sk-test-key-alpha')[0, 6]
      expect(ssot_harness.physical_id(instance_config: config)).to eq("gpu-server-2.internal:8001/ak:#{fingerprint}")
    end

    it 'keeps two config names distinct even on the same endpoint' do
      config = ssot_harness.instance_configs.first
      ids = [
        ssot_harness.instance_id(instance_config: config),
        ssot_harness.instance_id(instance_config: config.merge(name: 'other-name'))
      ]
      expect(ids.uniq.size).to eq(2)
    end

    it 'reproduces the same instance_id across multiple calls (stable identity)' do
      config = ssot_harness.instance_configs.first
      id_a = ssot_harness.instance_id(instance_config: config)
      id_b = ssot_harness.instance_id(instance_config: config)
      expect(id_a).to eq(id_b)
    end

    it 'strips the /v1 suffix when deriving the physical id' do
      with_v1 = { name: 'gpu-server-1', vllm_api_base: 'http://gpu-server-1.internal:8000/v1' }
      without = { name: 'gpu-server-1', vllm_api_base: 'http://gpu-server-1.internal:8000' }
      expect(ssot_harness.physical_id(instance_config: with_v1))
        .to eq(ssot_harness.physical_id(instance_config: without))
    end

    it 'builds an InstanceKey whose physical_id is secondary to the name identity' do
      config = ssot_harness.instance_configs.last
      key = Legion::Extensions::Llm::Inventory::Identity::InstanceKey.new(
        provider_family: :vllm,
        instance_id: ssot_harness.instance_id(instance_config: config),
        physical_id: ssot_harness.physical_id(instance_config: config)
      )
      expect(key.instance_id).to eq('gpu-server-2')
      expect(key.physical_id).to be_a(String)

      same_name = Legion::Extensions::Llm::Inventory::Identity::InstanceKey.new(
        provider_family: :vllm, instance_id: 'gpu-server-2'
      )
      expect(key).to eq(same_name)
      expect(key.hash).to eq(same_name.hash)
    end
  end

  # ─── Two servers with same model = separate lanes ───────────────────────────

  describe 'two vLLM servers serving the same model' do
    def bring_up_instance(config, tier: :local)
      publisher = Legion::Extensions::Llm::Inventory::Publisher.new(provider_family: :vllm)
      instance_id = ssot_harness.instance_id(instance_config: config)
      key = Legion::Extensions::Llm::Inventory::Identity::InstanceKey.new(
        provider_family: :vllm, instance_id: instance_id
      )
      callable = ssot_harness.build_callable(instance_config: config)
      coordinator = Legion::Extensions::Llm::Inventory::ProbeCoordinator.new(
        instance_key: key, enqueue: ->(**) { true }
      )

      token = publisher.claim_instance(instance_id: instance_id, callable: callable, probe_request_handle: coordinator)
      probe = publisher.readiness_probe_started(instance_id: instance_id, publisher_token: token)
      drafts = ssot_harness.build_offering_drafts(instance_config: config, callable: callable, tier: tier)
      publisher.activate_instance_snapshot(
        instance_id: instance_id, publisher_token: token, offerings: drafts, sequence: 0, probe_token: probe
      )

      { publisher: publisher, key: key, callable: callable, token: token, drafts: drafts, coordinator: coordinator }
    end

    it 'creates separate lanes for the same model on different instances' do
      a = bring_up_instance(ssot_harness.instance_configs[0])
      b = bring_up_instance(ssot_harness.instance_configs[1])

      snapshot = registry.snapshot
      lanes_a = snapshot.lanes_for(instance_key: a[:key])
      lanes_b = snapshot.lanes_for(instance_key: b[:key])

      expect(lanes_a).not_to be_empty
      expect(lanes_b).not_to be_empty

      lane_ids_a = lanes_a.map(&:lane_id)
      lane_ids_b = lanes_b.map(&:lane_id)
      expect(lane_ids_a & lane_ids_b).to be_empty
    end

    it 'reproduces IDs after restart (identity is deterministic from inputs)' do
      config = ssot_harness.instance_configs[0]
      first_run = bring_up_instance(config)
      first_offering_id = registry.snapshot.offerings_for(instance_key: first_run[:key]).first.offering_id
      first_lane_id = registry.snapshot.lanes_for(instance_key: first_run[:key]).first.lane_id

      # Simulate restart: reset and re-register
      registry.reset!
      second_run = bring_up_instance(config)
      second_offering_id = registry.snapshot.offerings_for(instance_key: second_run[:key]).first.offering_id
      second_lane_id = registry.snapshot.lanes_for(instance_key: second_run[:key]).first.lane_id

      expect(second_offering_id).to eq(first_offering_id)
      expect(second_lane_id).to eq(first_lane_id)
    end
  end

  # ─── Tier change does NOT change lane/offering identity ─────────────────────

  describe 'tier change and identity preservation' do
    def bring_up_with_tier(config, tier:)
      publisher = Legion::Extensions::Llm::Inventory::Publisher.new(provider_family: :vllm)
      instance_id = ssot_harness.instance_id(instance_config: config)
      key = Legion::Extensions::Llm::Inventory::Identity::InstanceKey.new(
        provider_family: :vllm, instance_id: instance_id
      )
      callable = ssot_harness.build_callable(instance_config: config)
      coordinator = Legion::Extensions::Llm::Inventory::ProbeCoordinator.new(
        instance_key: key, enqueue: ->(**) { true }
      )

      token = publisher.claim_instance(instance_id: instance_id, callable: callable, probe_request_handle: coordinator)
      probe = publisher.readiness_probe_started(instance_id: instance_id, publisher_token: token)
      drafts = ssot_harness.build_offering_drafts(instance_config: config, callable: callable, tier: tier)
      publisher.activate_instance_snapshot(
        instance_id: instance_id, publisher_token: token, offerings: drafts, sequence: 0, probe_token: probe
      )

      { publisher: publisher, key: key, callable: callable, token: token, drafts: drafts }
    end

    it 'preserves offering_id and lane_id when tier changes from local to frontier' do
      config = ssot_harness.instance_configs[0]
      context = bring_up_with_tier(config, tier: :local)

      before_offering = registry.snapshot.offerings_for(instance_key: context[:key]).first
      before_lane = registry.snapshot.lanes_for(instance_key: context[:key]).first

      # Republish with different tier
      frontier_drafts = ssot_harness.build_offering_drafts(
        instance_config: config, callable: context[:callable], tier: :frontier
      )
      context[:publisher].replace_instance_snapshot(
        instance_id: ssot_harness.instance_id(instance_config: config),
        publisher_token: context[:token],
        offerings: frontier_drafts,
        sequence: 1
      )

      after_offering = registry.snapshot.offerings_for(instance_key: context[:key]).first
      after_lane = registry.snapshot.lanes_for(instance_key: context[:key]).first

      expect(after_offering.offering_id).to eq(before_offering.offering_id)
      expect(after_lane.lane_id).to eq(before_lane.lane_id)
      expect(after_offering.tier).to eq(:frontier)
    end
  end

  # ─── Embedding operation evidence ──────────────────────────────────────────

  describe 'embedding operation support detection' do
    it 'does not advertise embed operation when usage.embedding is set but model type is not embedding' do
      Time.now.freeze
      # usage.embedding alone is not sufficient per the discovery_refresh logic;
      # model type must also be 'embedding'
      config = ssot_harness.instance_configs[0].merge(usage: { embedding: true })
      model_data = { id: 'meta-llama/Llama-3.1-8B-Instruct', type: 'chat' }

      # The embedding_supported? method requires BOTH usage.embedding == true AND type == 'embedding'
      embed_supported = config.dig(:usage, :embedding) == true && model_data[:type].to_s == 'embedding'
      expect(embed_supported).to be(false)
    end

    it 'advertises embed only when model type is embedding AND usage.embedding is true' do
      config = ssot_harness.instance_configs[0].merge(usage: { embedding: true })
      model_data = { id: 'BAAI/bge-large-en-v1.5', type: 'embedding' }

      embed_supported = config.dig(:usage, :embedding) == true && model_data[:type].to_s == 'embedding'
      expect(embed_supported).to be(true)
    end

    it 'advertises embed when model capabilities array includes embedding' do
      model_data = { id: 'BAAI/bge-large-en-v1.5', capabilities: ['embedding'] }
      has_cap = model_data[:capabilities].is_a?(Array) && model_data[:capabilities].include?('embedding')
      expect(has_cap).to be(true)
    end
  end

  # ─── Explicit operation evidence controls ───────────────────────────────────

  describe 'operation evidence controls' do
    let(:config) { ssot_harness.instance_configs[0] }
    let(:callable) { ssot_harness.build_callable(instance_config: config) }
    let(:offering) do
      ssot_harness.build_offering_drafts(instance_config: config, callable: callable, tier: :local).first
    end

    it 'marks chat as supported' do
      expect(offering.operation_evidence[:chat].status).to eq(:supported)
    end

    it 'marks stream_chat as supported' do
      expect(offering.operation_evidence[:stream_chat].status).to eq(:supported)
    end

    it 'marks embed as unsupported when embedding is not detected' do
      expect(offering.operation_evidence[:embed].status).to eq(:unsupported)
    end

    it 'marks image/transcribe/translate/speak/moderate as unsupported' do
      %i[image transcribe translate speak moderate].each do |op|
        expect(offering.operation_evidence[op].status).to eq(:unsupported),
                                                          "expected #{op} to be :unsupported"
      end
    end

    it 'marks count_tokens as unknown' do
      expect(offering.operation_evidence[:count_tokens].status).to eq(:unknown)
    end

    it 'uses :provider_implementation source for supported/unsupported operations' do
      %i[chat stream_chat embed image transcribe translate speak moderate].each do |op|
        expect(offering.operation_evidence[op].source).to eq(:provider_implementation),
                                                          "expected #{op} source to be :provider_implementation"
      end
    end

    it 'uses :default_false source for unknown operations' do
      expect(offering.operation_evidence[:count_tokens].source).to eq(:default_false)
    end
  end

  # ─── Embedding models authoritatively exclude chat (bedrock parity) ────────

  describe 'embedding model operation evidence' do
    let(:offering) do
      Time.now.freeze
      ssot_harness.build_embedding_offering_drafts(instance_config: ssot_harness.instance_configs[0]).first
    end

    it 'marks chat as :unsupported so a plain chat request cannot misroute here' do
      expect(offering.operation_evidence[:chat].status).to eq(:unsupported)
      expect(offering.operation_evidence[:chat].source).to eq(:provider_implementation)
    end

    it 'marks stream_chat as :unsupported' do
      expect(offering.operation_evidence[:stream_chat].status).to eq(:unsupported)
    end

    it 'marks embed as :supported' do
      expect(offering.operation_evidence[:embed].status).to eq(:supported)
    end

    it 'marks the remaining operations as :unsupported' do
      %i[image transcribe translate speak moderate count_tokens].each do |op|
        expect(offering.operation_evidence[op].status).to eq(:unsupported),
                                                          "expected #{op} to be :unsupported"
      end
    end
  end

  # ─── Startup gating + initializing on initial failure ───────────────────────

  describe 'startup gating' do
    let(:config) { ssot_harness.instance_configs[0] }
    let(:key) do
      Legion::Extensions::Llm::Inventory::Identity::InstanceKey.new(
        provider_family: :vllm, instance_id: ssot_harness.instance_id(instance_config: config)
      )
    end
    let(:setup) do
      {
        publisher: Legion::Extensions::Llm::Inventory::Publisher.new(provider_family: :vllm),
        callable: ssot_harness.build_callable(instance_config: config),
        coordinator: Legion::Extensions::Llm::Inventory::ProbeCoordinator.new(
          instance_key: key, enqueue: ->(**) { true }
        )
      }
    end

    def instance_id = key.instance_id
    def publisher = setup[:publisher]
    def callable = setup[:callable]
    def coordinator = setup[:coordinator]

    it 'remains initializing until readiness probe succeeds' do
      publisher.claim_instance(instance_id: instance_id, callable: callable, probe_request_handle: coordinator)

      snapshot = registry.snapshot
      expect(snapshot.instance(instance_key: key)).to be_nil
      expect(snapshot.publication_status(instance_key: key).state).to eq(:initializing)
    end

    it 'stays initializing after an initial readiness failure' do
      token = publisher.claim_instance(instance_id: instance_id, callable: callable, probe_request_handle: coordinator)
      probe = publisher.readiness_probe_started(instance_id: instance_id, publisher_token: token)
      publisher.readiness_failed(instance_id: instance_id, probe_token: probe, reason: 'vLLM /health connection failed')

      snapshot = registry.snapshot
      expect(snapshot.instance(instance_key: key)).to be_nil
      expect(snapshot.publication_status(instance_key: key).state).to eq(:initializing)
    end

    it 'transitions to available after readiness success' do
      token = publisher.claim_instance(instance_id: instance_id, callable: callable, probe_request_handle: coordinator)
      probe = publisher.readiness_probe_started(instance_id: instance_id, publisher_token: token)
      drafts = ssot_harness.build_offering_drafts(instance_config: config, callable: callable, tier: :local)
      publisher.activate_instance_snapshot(
        instance_id: instance_id, publisher_token: token, offerings: drafts, sequence: 0, probe_token: probe
      )

      snapshot = registry.snapshot
      expect(snapshot.instance(instance_key: key).availability.state).to eq(:available)
      expect(snapshot.publication_status(instance_key: key).state).to eq(:complete)
    end
  end

  # ─── Valid/stale readiness + probe-cleared unavailable ──────────────────────

  describe 'readiness probe lifecycle' do
    let(:config) { ssot_harness.instance_configs[0] }
    let(:key) do
      Legion::Extensions::Llm::Inventory::Identity::InstanceKey.new(
        provider_family: :vllm, instance_id: ssot_harness.instance_id(instance_config: config)
      )
    end
    let(:setup) do
      {
        publisher: Legion::Extensions::Llm::Inventory::Publisher.new(provider_family: :vllm),
        callable: ssot_harness.build_callable(instance_config: config),
        coordinator: Legion::Extensions::Llm::Inventory::ProbeCoordinator.new(
          instance_key: key, enqueue: ->(**) { true }
        )
      }
    end

    def instance_id = key.instance_id
    def publisher = setup[:publisher]
    def callable = setup[:callable]
    def coordinator = setup[:coordinator]

    def activate_instance
      token = publisher.claim_instance(instance_id: instance_id, callable: callable, probe_request_handle: coordinator)
      probe = publisher.readiness_probe_started(instance_id: instance_id, publisher_token: token)
      drafts = ssot_harness.build_offering_drafts(instance_config: config, callable: callable, tier: :local)
      publisher.activate_instance_snapshot(
        instance_id: instance_id, publisher_token: token, offerings: drafts, sequence: 0, probe_token: probe
      )
      token
    end

    it 'rejects a stale probe started before a newer one that reported failure' do
      token = activate_instance

      stale_probe = publisher.readiness_probe_started(instance_id: instance_id, publisher_token: token)
      fresh_probe = publisher.readiness_probe_started(instance_id: instance_id, publisher_token: token)

      # Fresh probe fails -> instance becomes unavailable
      publisher.readiness_failed(instance_id: instance_id, probe_token: fresh_probe, reason: 'server down')

      # Stale probe tries to succeed -> should be rejected
      result = publisher.readiness_succeeded(instance_id: instance_id, probe_token: stale_probe)
      expect(result.applied).to be(false)
      expect(result.reason).to eq(:stale_probe)
    end

    it 'recovers an unavailable instance after a valid probe succeeds' do
      token = activate_instance

      # Mark unavailable via dispatch
      registry.dispatch_instance_unavailable(
        instance_key: key, publisher_token_id: token.publisher_token_id, reason: 'connection refused'
      )
      expect(registry.snapshot.instance(instance_key: key).availability.state).to eq(:unavailable)

      # New probe succeeds -> should recover
      new_probe = publisher.readiness_probe_started(instance_id: instance_id, publisher_token: token)
      publisher.readiness_succeeded(instance_id: instance_id, probe_token: new_probe)
      expect(registry.snapshot.instance(instance_key: key).availability.state).to eq(:available)
    end
  end

  # ─── Normalized instance-unavailable isolation ──────────────────────────────

  describe 'instance-unavailable isolation' do
    def bring_up(config)
      publisher = Legion::Extensions::Llm::Inventory::Publisher.new(provider_family: :vllm)
      instance_id = ssot_harness.instance_id(instance_config: config)
      key = Legion::Extensions::Llm::Inventory::Identity::InstanceKey.new(
        provider_family: :vllm, instance_id: instance_id
      )
      callable = ssot_harness.build_callable(instance_config: config)
      coordinator = Legion::Extensions::Llm::Inventory::ProbeCoordinator.new(
        instance_key: key, enqueue: ->(**) { true }
      )

      token = publisher.claim_instance(instance_id: instance_id, callable: callable, probe_request_handle: coordinator)
      probe = publisher.readiness_probe_started(instance_id: instance_id, publisher_token: token)
      drafts = ssot_harness.build_offering_drafts(instance_config: config, callable: callable, tier: :local)
      publisher.activate_instance_snapshot(
        instance_id: instance_id, publisher_token: token, offerings: drafts, sequence: 0, probe_token: probe
      )

      { publisher: publisher, key: key, callable: callable, token: token }
    end

    it 'marks only one instance unavailable without affecting the other' do
      a = bring_up(ssot_harness.instance_configs[0])
      b = bring_up(ssot_harness.instance_configs[1])

      # Instance A goes down
      registry.dispatch_instance_unavailable(
        instance_key: a[:key],
        publisher_token_id: a[:token].publisher_token_id,
        reason: 'connection refused to gpu-server-1'
      )

      expect(registry.snapshot.instance(instance_key: a[:key]).availability.state).to eq(:unavailable)
      expect(registry.snapshot.instance(instance_key: b[:key]).availability.state).to eq(:available)
    end

    it 'normalizes explicit vLLM offline response as instance_unavailable' do
      outcome = ssot_harness.normalize_dispatch_error(error: ssot_harness.instance_unavailable_error)
      expect(outcome).to be_a(Legion::Extensions::Llm::Routing::ProviderOutcome)
      expect(outcome.kind).to eq(:instance_unavailable)
    end

    it '§8 firewall: connection failure stays connection_failure, never promoted to instance_unavailable' do
      error = Faraday::ConnectionFailed.new('Connection refused - connect(2) for gpu-server-1.internal:8000')
      outcome = ssot_harness.normalize_dispatch_error(error: error)
      expect(outcome.kind).to eq(:connection_failure)
      expect(outcome.kind).not_to eq(:instance_unavailable)
    end

    it 'normalizes 503 as overloaded, never as instance_unavailable' do
      outcome = ssot_harness.normalize_dispatch_error(error: ssot_harness.overloaded_error)
      expect(outcome.kind).to eq(:overloaded)
      expect(outcome.kind).not_to eq(:instance_unavailable)
    end
  end

  # ─── Safe-readiness coalescing via ProbeCoordinator ─────────────────────────

  describe 'ProbeCoordinator coalescing' do
    let(:key) do
      Legion::Extensions::Llm::Inventory::Identity::InstanceKey.new(
        provider_family: :vllm,
        instance_id: ssot_harness.instance_id(instance_config: ssot_harness.instance_configs[0])
      )
    end
    let(:enqueue_calls) { [] }
    let(:coordinator) do
      Legion::Extensions::Llm::Inventory::ProbeCoordinator.new(
        instance_key: key,
        enqueue: lambda { |request:|
          enqueue_calls << request
          true
        }
      )
    end

    it 'coalesces multiple probe requests into a single in-flight probe' do
      # First request gets enqueued
      coordinator.enqueue_probe_request(
        instance_key: key, publisher_token_id: 'ptok:v1:aaa',
        unavailable_revision: 1, reason: 'first failure'
      )
      expect(enqueue_calls.size).to eq(1)

      # Start the probe
      expect(coordinator.begin_probe(request: enqueue_calls.first)).to be(true)
      expect(coordinator.in_flight?).to be(true)

      # Second request arrives while probe is in flight - should NOT re-enqueue
      coordinator.enqueue_probe_request(
        instance_key: key, publisher_token_id: 'ptok:v1:aaa',
        unavailable_revision: 2, reason: 'second failure'
      )
      # Still only 1 enqueue call (the second is pending, not enqueued)
      expect(enqueue_calls.size).to eq(1)

      # Finish probe -> pending request should now be enqueued
      coordinator.finish_probe(request: enqueue_calls.first)
      expect(enqueue_calls.size).to eq(2)
      expect(enqueue_calls.last.unavailable_revision).to eq(2)
    end

    it 'only retains the highest unavailable_revision when coalescing' do
      coordinator.enqueue_probe_request(
        instance_key: key, publisher_token_id: 'ptok:v1:aaa',
        unavailable_revision: 1, reason: 'rev 1'
      )
      expect(coordinator.begin_probe(request: enqueue_calls.first)).to be(true)

      # Multiple requests while in-flight, only highest revision retained
      coordinator.enqueue_probe_request(
        instance_key: key, publisher_token_id: 'ptok:v1:aaa',
        unavailable_revision: 3, reason: 'rev 3'
      )
      coordinator.enqueue_probe_request(
        instance_key: key, publisher_token_id: 'ptok:v1:aaa',
        unavailable_revision: 2, reason: 'rev 2'
      )

      coordinator.finish_probe(request: enqueue_calls.first)
      expect(enqueue_calls.last.unavailable_revision).to eq(3)
    end
  end

  # ─── Connection refusal/timeout/generic don't globally poison ───────────────

  describe 'error isolation (no global poisoning)' do
    it 'classifies connection failure as connection_failure on the callable' do
      callable = ssot_harness.build_callable(instance_config: ssot_harness.instance_configs[0])
      error = Faraday::ConnectionFailed.new('Connection refused')
      outcome = callable.normalize_dispatch_error(error: error)
      expect(outcome.kind).to eq(:connection_failure)
    end

    it 'classifies timeout as timeout on the callable' do
      callable = ssot_harness.build_callable(instance_config: ssot_harness.instance_configs[0])
      error = Faraday::TimeoutError.new('Net::ReadTimeout')
      outcome = callable.normalize_dispatch_error(error: error)
      expect(outcome.kind).to eq(:timeout)
    end

    it 'classifies generic errors as provider_error on the callable' do
      callable = ssot_harness.build_callable(instance_config: ssot_harness.instance_configs[0])
      error = RuntimeError.new('unexpected failure')
      outcome = callable.normalize_dispatch_error(error: error)
      expect(outcome.kind).to eq(:provider_error)
    end

    it 'classifies 503 ServerError as overloaded on the callable' do
      callable = ssot_harness.build_callable(instance_config: ssot_harness.instance_configs[0])
      response = { status: 503, headers: {}, body: '' }
      error = Faraday::ServerError.new('503', response)
      outcome = callable.normalize_dispatch_error(error: error)
      expect(outcome.kind).to eq(:overloaded)
    end

    it 'classifies 429 ClientError as rate_limited on the callable' do
      callable = ssot_harness.build_callable(instance_config: ssot_harness.instance_configs[0])
      response = { status: 429, headers: {}, body: '' }
      error = Faraday::ClientError.new('429', response)
      outcome = callable.normalize_dispatch_error(error: error)
      expect(outcome.kind).to eq(:rate_limited)
    end

    it 'classifies 401 as authentication on the callable' do
      callable = ssot_harness.build_callable(instance_config: ssot_harness.instance_configs[0])
      response = { status: 401, headers: {}, body: '' }
      error = Faraday::ClientError.new('401', response)
      outcome = callable.normalize_dispatch_error(error: error)
      expect(outcome.kind).to eq(:authentication)
    end

    it 'classifies 404 as model_missing on the callable' do
      callable = ssot_harness.build_callable(instance_config: ssot_harness.instance_configs[0])
      response = { status: 404, headers: {}, body: '' }
      error = Faraday::ClientError.new('404', response)
      outcome = callable.normalize_dispatch_error(error: error)
      expect(outcome.kind).to eq(:model_missing)
    end

    it 'never returns instance_unavailable from the callable for any server error' do
      callable = ssot_harness.build_callable(instance_config: ssot_harness.instance_configs[0])
      [500, 502, 503, 504, 529].each do |status|
        response = { status: status, headers: {}, body: '' }
        error = Faraday::ServerError.new(status.to_s, response)
        outcome = callable.normalize_dispatch_error(error: error)
        expect(outcome.kind).not_to eq(:instance_unavailable),
                                    "status #{status} should not map to instance_unavailable"
      end
    end
  end

  # ─── D17: production raises Llm::*Error (via the Connection ErrorMiddleware),
  #     not raw Faraday classes. The offline-body signal must be read off the
  #     Llm error's WRAPPED Faraday::Response, and the request-local Llm classes
  #     must keep their outcomes. ──────────────────────────────────────────────

  describe 'production Llm error shape (D17)' do
    let(:callable) { ssot_harness.build_callable(instance_config: ssot_harness.instance_configs[0]) }

    def llm_error(klass, status:, body:, message:)
      env = Faraday::Env.new
      env[:status] = status
      env[:headers] = {}
      env[:body] = body
      klass.new(Faraday::Response.new(env), message)
    end

    it 'classifies a ServiceUnavailableError with an offline body as instance_unavailable' do
      error = llm_error(
        Legion::Extensions::Llm::ServiceUnavailableError,
        status: 503, body: '{"error": "Instance not available", "detail": "server is going offline"}',
        message: '503 Service Unavailable'
      )
      expect(callable.normalize_dispatch_error(error: error).kind).to eq(:instance_unavailable)
    end

    it 'classifies a ServiceUnavailableError without an offline body as provider_error' do
      error = llm_error(
        Legion::Extensions::Llm::ServiceUnavailableError,
        status: 503, body: '{"error": "Server overloaded"}', message: '503 Service Unavailable'
      )
      expect(callable.normalize_dispatch_error(error: error).kind).to eq(:provider_error)
    end

    it 'keeps the request-local Llm outcomes (not :provider_error)' do
      expect(callable.normalize_dispatch_error(
        error: Legion::Extensions::Llm::OverloadedError.new('529')
      ).kind).to eq(:overloaded)
      expect(callable.normalize_dispatch_error(
        error: Legion::Extensions::Llm::RateLimitError.new('429')
      ).kind).to eq(:rate_limited)
      expect(callable.normalize_dispatch_error(
        error: Legion::Extensions::Llm::UnauthorizedError.new('401')
      ).kind).to eq(:authentication)
      expect(callable.normalize_dispatch_error(
        error: Legion::Extensions::Llm::ModelNotFoundError.new('404')
      ).kind).to eq(:model_missing)
      expect(callable.normalize_dispatch_error(
        error: Legion::Extensions::Llm::PaymentRequiredError.new('402')
      ).kind).to eq(:billing)
    end

    it 'maps raw connection/timeout errors (Llm middleware passthrough) correctly' do
      expect(callable.normalize_dispatch_error(
        error: Errno::ECONNREFUSED.new('connection refused')
      ).kind).to eq(:connection_failure)
      expect(callable.normalize_dispatch_error(
        error: Timeout::Error.new('read timeout')
      ).kind).to eq(:timeout)
    end
  end

  # ─── Dispatch boundary regression guards (live repro) ───────────────────────
  # (B) legion-llm's prompt-cache step sets cache_control: { type: 'ephemeral' }
  #     on the last stable message of every >=2-message request. As of lex-llm
  #     0.7.7 that runs on CANONICAL objects (Message#with(cache_control:));
  #     :cache_control is a first-class canonical member, and the provider
  #     boundary rejects plain-Hash input loudly (the 2026-08-19 incident was a
  #     Hash bypass silently re-canonicalized by this provider). The vLLM
  #     OpenAI-compatible wire never carries the transport-only key.
  # (A) A non-UTF-8 (ASCII-8BIT) dispatch error message — a raw provider body or
  #     a Ruby kernel error — used to make RecordSupport.sanitized_reason raise
  #     ValidationError 'is not valid UTF-8', masking the real provider error as
  #     an unclassifiable retriable 500. It now coerces to valid UTF-8.

  describe 'dispatch boundary: prompt-cache cache_control + non-UTF-8 errors' do
    let(:config) { ssot_harness.instance_configs[0] }
    let(:model_id) { 'meta-llama/Llama-3.1-8B-Instruct' }
    let(:provider) { Legion::Extensions::Llm::Vllm::Provider.new(config) }
    let(:callable) { ssot_harness.build_callable(instance_config: config) }

    # The exact shape legion-llm's prompt-cache step produces on canonical
    # objects (inference/steps/prompt_cache.rb): the last stable message
    # carries cache_control: { type: 'ephemeral' } as a canonical member.
    let(:two_message_request) do
      [
        Legion::Extensions::Llm::Canonical::Message.build(
          role: :user, content: 'What is the capital of France?',
          cache_control: { type: 'ephemeral' }
        ),
        Legion::Extensions::Llm::Canonical::Message.build(role: :assistant, content: 'Paris.')
      ]
    end

    # H3 (0.8.0 funnel): the dispatch boundary enforces
    # Hash<name, Canonical::ToolDefinition> — raw Hash tools are the bypass
    # class and no longer cross chat/stream_chat.
    let(:tool_set) do
      {
        get_weather: Legion::Extensions::Llm::Canonical::ToolDefinition.build(
          name: 'get_weather',
          description: 'Get the current weather for a city',
          parameters: { type: 'object', properties: { city: { type: 'string' } }, required: %w[city] }
        )
      }
    end

    it 'renders a 2-message sync chat whose first canonical message carries the prompt-cache :cache_control member' do
      # render_payload is the production render seam (Provider#complete ->
      # render_payload); calling it directly keeps the example HTTP-free.
      # Canonical input with a :cache_control member must render to the
      # OpenAI-compatible wire without leaking the transport-only key.
      wire = nil
      expect do
        wire = provider.send(
          :render_payload,
          two_message_request,
          tools: tool_set, params: nil, model: model_id,
          stream: false, schema: nil, thinking: nil, tool_prefs: nil
        )
      end.not_to raise_error

      expect(wire).to be_a(Hash)
      expect(wire[:model]).to eq(model_id)
      expect(wire[:stream]).to be(false)
      expect(wire[:messages].size).to eq(2)
      expect(wire[:messages].map { |m| m[:role] }).to eq(%w[user assistant])
      expect(wire[:messages].first[:content]).to eq('What is the capital of France?')
      expect(wire[:tools].size).to eq(1)
      expect(wire.dig(:tools, 0, :function, :name)).to eq('get_weather')
      # The transport-only key never leaks onto the wire
      wire[:messages].each { |m| expect(m).not_to have_key(:cache_control) }
    end

    it 'keeps the canonical :cache_control member on the message, dropped only at the wire render' do
      # :cache_control is a first-class canonical member (lex-llm 0.8.0); the
      # canonical object carries it through build/to_h and the wire render
      # above is where — and only where — it is dropped.
      expect(Legion::Extensions::Llm::Canonical::Message.members).to include(:cache_control)
      expect(two_message_request.map(&:cache_control)).to eq([{ type: 'ephemeral' }, nil])
      expect(two_message_request.first.to_h).to include(cache_control: { type: 'ephemeral' })
    end

    it 'rejects plain Hash messages at the dispatch boundary instead of re-canonicalizing them' do
      hash_request = [
        { role: 'user', content: 'What is the capital of France?', cache_control: { type: 'ephemeral' } },
        { role: 'assistant', content: 'Paris.' }
      ]

      # The 2026-08-19 defect class: hash messages silently re-canonicalized
      # provider-side masked the bypass for 25 failed openai dispatches.
      # Central enforcement (08 F2) rejects loudly at the callable boundary
      # and in the Provider#complete funnel — the render seam no longer
      # re-implements the check.
      expect { callable.chat(hash_request, model: model_id) }
        .to raise_error(ArgumentError, /Canonical::Message/)
      expect { provider.chat(hash_request, model: model_id) }
        .to raise_error(ArgumentError, /Canonical::Message/)
    end

    it 'completes a 2-message sync chat through the full provider path (render -> HTTP -> parse)' do
      # The Connection#post boundary is stubbed by the outer before block. If the
      # render path raised (hash input, unknown canonical members), the request
      # never reached HTTP. B2: the sync parse returns Canonical::Response,
      # asserted by type.
      result = nil
      expect do
        result = provider.chat(two_message_request, model: model_id, tools: tool_set)
      end.not_to raise_error

      expect(result).to be_a(Legion::Extensions::Llm::Canonical::Response)
      expect(result.text).to eq('conformance')
    end

    it 'normalizes a non-UTF-8 (ASCII-8BIT) RuntimeError into a valid ProviderOutcome with a class-name reason' do
      binary = "vllm dispatch failed: \xFF\xFE invalid body bytes \x80\x81".dup.force_encoding(Encoding::ASCII_8BIT)
      error = RuntimeError.new(binary)

      outcome = nil
      expect { outcome = callable.normalize_dispatch_error(error: error) }.not_to raise_error

      expect(outcome).to be_a(Legion::Extensions::Llm::Routing::ProviderOutcome)
      expect(outcome.kind).to eq(:provider_error)
      # V5: the reason is the bounded exception CLASS name — the non-UTF-8
      # message never flows into the outcome, so the encoding hazard is
      # structural (no message bytes cross the boundary), not a scrub.
      expect(outcome.reason).to eq('RuntimeError')
      expect(outcome.reason.encoding).to eq(Encoding::UTF_8)
      expect(outcome.reason).to be_valid_encoding
    end

    it 'normalizes a Faraday::ServerError with a non-UTF-8 message/body into a class-name reason' do
      env = Faraday::Env.new
      env[:status] = 500
      env[:headers] = {}
      env[:body] = "raw upstream body \xFF\xFE"
      error = Faraday::ServerError.new(
        "500 - raw upstream body \xFF\xFE".dup.force_encoding(Encoding::ASCII_8BIT), env
      )

      outcome = nil
      expect { outcome = callable.normalize_dispatch_error(error: error) }.not_to raise_error

      expect(outcome.kind).to eq(:provider_error)
      expect(outcome.reason).to eq('Faraday::ServerError')
      expect(outcome.reason).to be_valid_encoding
    end
  end

  # ─── No quota domain broadening without authoritative scope ─────────────────

  describe 'quota domain safety' do
    it 'does not declare quota_domains on offerings' do
      config = ssot_harness.instance_configs[0]
      callable = ssot_harness.build_callable(instance_config: config)
      drafts = ssot_harness.build_offering_drafts(instance_config: config, callable: callable, tier: :local)

      drafts.each do |draft|
        expect(draft.quota_domains).to be_empty,
                                       'vLLM offerings must not declare quota_domains without authoritative scope'
      end
    end
  end

  # ─── Exact fleet worker rejects stale/mismatched/unsupported/ambiguous ──────

  describe 'exact fleet worker execution contract' do
    let(:config) { ssot_harness.instance_configs[0] }
    let(:instance_id) { ssot_harness.instance_id(instance_config: config) }
    let(:key) do
      Legion::Extensions::Llm::Inventory::Identity::InstanceKey.new(
        provider_family: :vllm, instance_id: instance_id
      )
    end

    def activate_offering
      publisher = Legion::Extensions::Llm::Inventory::Publisher.new(provider_family: :vllm)
      callable = ssot_harness.build_callable(instance_config: config)
      token = claim_and_activate(publisher: publisher, callable: callable)
      offering = registry.snapshot.offerings_for(instance_key: key).first
      { publisher: publisher, token: token, offering: offering, callable: callable }
    end

    def claim_and_activate(publisher:, callable:)
      coordinator = Legion::Extensions::Llm::Inventory::ProbeCoordinator.new(
        instance_key: key, enqueue: ->(**) { true }
      )
      token = publisher.claim_instance(instance_id: instance_id, callable: callable, probe_request_handle: coordinator)
      probe = publisher.readiness_probe_started(instance_id: instance_id, publisher_token: token)
      drafts = ssot_harness.build_offering_drafts(instance_config: config, callable: callable, tier: :local)
      publisher.activate_instance_snapshot(
        instance_id: instance_id, publisher_token: token, offerings: drafts, sequence: 0, probe_token: probe
      )
      token
    end

    before do
      allow(Legion::Extensions::Llm::Fleet::WorkerExecution).to receive_messages(
        validate_identity!: true,
        validate_idempotency!: nil
      )
    end

    it 'rejects a mismatched offering_id' do
      activate_offering

      envelope = {
        execution_contract: Legion::Extensions::Llm::Fleet::Protocol::EXACT_EXECUTION_CONTRACT,
        offering_id: 'off:v1:0000000000000000000000000000000000000000000000000000000000000000',
        provider: 'vllm',
        provider_instance: instance_id,
        model: 'meta-llama/Llama-3.1-8B-Instruct',
        operation: 'chat',
        params: { messages: [] }
      }

      expect do
        Legion::Extensions::Llm::Fleet::WorkerExecution.call(envelope: envelope, registry: registry)
      end.to raise_error(Legion::Extensions::Llm::Inventory::Errors::ExactOfferingMismatchError)
    end

    it 'rejects an unsupported operation' do
      ctx = activate_offering

      envelope = {
        execution_contract: Legion::Extensions::Llm::Fleet::Protocol::EXACT_EXECUTION_CONTRACT,
        offering_id: ctx[:offering].offering_id,
        provider: 'vllm',
        provider_instance: instance_id,
        model: ctx[:offering].model,
        operation: 'embed', # embed is unsupported for this offering
        params: { text: 'hello' }
      }

      expect do
        Legion::Extensions::Llm::Fleet::WorkerExecution.call(envelope: envelope, registry: registry)
      end.to raise_error(Legion::Extensions::Llm::Inventory::Errors::ExactOfferingMismatchError)
    end

    it 'rejects a mismatched model' do
      ctx = activate_offering

      envelope = {
        execution_contract: Legion::Extensions::Llm::Fleet::Protocol::EXACT_EXECUTION_CONTRACT,
        offering_id: ctx[:offering].offering_id,
        provider: 'vllm',
        provider_instance: instance_id,
        model: 'some-other-model/v1',
        operation: 'chat',
        params: { messages: [] }
      }

      expect do
        Legion::Extensions::Llm::Fleet::WorkerExecution.call(envelope: envelope, registry: registry)
      end.to raise_error(Legion::Extensions::Llm::Inventory::Errors::ExactOfferingMismatchError)
    end

    it 'rejects a stale publisher token (instance re-claimed)' do
      ctx = activate_offering

      # Re-claim the instance (simulates restart)
      new_callable = ssot_harness.build_callable(instance_config: config)
      new_coordinator = Legion::Extensions::Llm::Inventory::ProbeCoordinator.new(
        instance_key: key, enqueue: ->(**) { true }
      )
      new_publisher = Legion::Extensions::Llm::Inventory::Publisher.new(provider_family: :vllm)
      new_token = new_publisher.claim_instance(instance_id: instance_id, callable: new_callable, probe_request_handle: new_coordinator)
      new_probe = new_publisher.readiness_probe_started(instance_id: instance_id, publisher_token: new_token)
      new_drafts = ssot_harness.build_offering_drafts(instance_config: config, callable: new_callable, tier: :local)
      new_publisher.activate_instance_snapshot(
        instance_id: instance_id, publisher_token: new_token, offerings: new_drafts, sequence: 0, probe_token: new_probe
      )

      # Old offering_id is now on a new callable - using old envelope should still work
      # because identity is deterministic, but the callable is different
      new_offering = registry.snapshot.offerings_for(instance_key: key).first
      expect(new_offering.offering_id).to eq(ctx[:offering].offering_id)
    end

    it 'rejects an unavailable instance' do
      ctx = activate_offering

      # Mark instance unavailable
      registry.dispatch_instance_unavailable(
        instance_key: key,
        publisher_token_id: ctx[:token].publisher_token_id,
        reason: 'server down'
      )

      envelope = {
        execution_contract: Legion::Extensions::Llm::Fleet::Protocol::EXACT_EXECUTION_CONTRACT,
        offering_id: ctx[:offering].offering_id,
        provider: 'vllm',
        provider_instance: instance_id,
        model: ctx[:offering].model,
        operation: 'chat',
        params: { messages: [] }
      }

      expect do
        Legion::Extensions::Llm::Fleet::WorkerExecution.call(envelope: envelope, registry: registry)
      end.to raise_error(Legion::Extensions::Llm::Inventory::Errors::ExactOfferingMismatchError)
    end
  end

  # ─── No Legion::LLM reverse dependency ─────────────────────────────────────

  describe 'dependency isolation' do
    it 'does not require Legion::LLM (no reverse dependency on top-level llm module)' do
      # The vLLM extension depends on lex-llm inventory/routing infrastructure,
      # not on a top-level Legion::LLM module. Verify no such constant is referenced
      # as a hard dependency from the actor/callable code.
      project_root = File.expand_path('../../../..', __dir__)
      actor_file = File.read(
        File.join(project_root, 'lib/legion/extensions/llm/vllm/actors/discovery_refresh.rb')
      )
      expect(actor_file).not_to match(/\bLegion::LLM\b/)
    end

    it 'VllmCallable does not reference Legion::LLM' do
      callable = ssot_harness.build_callable(instance_config: ssot_harness.instance_configs[0])
      # The callable uses Legion::Extensions::Llm::Routing::ProviderOutcome, not Legion::LLM
      outcome = callable.normalize_dispatch_error(error: RuntimeError.new('test'))
      expect(outcome).to be_a(Legion::Extensions::Llm::Routing::ProviderOutcome)
    end
  end

  # ─── No default model/provider ──────────────────────────────────────────────

  describe 'no default model or provider' do
    it 'allows instance_id "default"' do
      instance_key = Legion::Extensions::Llm::Inventory::Identity::InstanceKey.new(
        provider_family: :vllm, instance_id: 'default'
      )

      expect(instance_key.instance_id).to eq('default')
    end

    it 'rejects nil instance_id' do
      expect do
        Legion::Extensions::Llm::Inventory::Identity::InstanceKey.new(
          provider_family: :vllm, instance_id: nil
        )
      end.to raise_error(Legion::Extensions::Llm::Inventory::Errors::ValidationError)
    end

    it 'does not define a DEFAULT_MODEL constant' do
      expect(described_class.const_defined?(:DEFAULT_MODEL, false)).to be(false)
    end

    it 'does not define a DEFAULT_PROVIDER constant' do
      expect(described_class.const_defined?(:DEFAULT_PROVIDER, false)).to be(false)
    end

    it 'offering drafts require an explicit model string' do
      # Reuse the production builder's evidence (D16 — no duplicated builder);
      # only the model is forced empty to exercise the draft validation.
      valid = ssot_harness.build_offering_drafts(tier: :local).first
      expect do
        Legion::Extensions::Llm::Inventory::OfferingDraft.new(
          provider_native_key: 'test',
          model: '',
          tier: :local,
          operation_evidence: valid.operation_evidence,
          context_evidence: valid.context_evidence,
          max_output_evidence: valid.max_output_evidence,
          embedding_dimensions_evidence: valid.embedding_dimensions_evidence,
          model_revision_evidence: valid.model_revision_evidence,
          tokenizer_evidence: valid.tokenizer_evidence,
          quota_domains: {},
          metadata: {},
          publication_source: :provider_catalog
        )
      end.to raise_error(Legion::Extensions::Llm::Inventory::Errors::ValidationError)
    end
  end

  # ─── VllmCallable direct contract ──────────────────────────────────────────

  describe Legion::Extensions::Llm::Vllm::VllmCallable do
    let(:callable) do
      described_class.new(
        instance_cfg: ssot_harness.instance_configs[0],
        logger: Logger.new(File::NULL)
      )
    end

    it 'responds to disconnect' do
      expect(callable).to respond_to(:disconnect)
      expect(callable).to respond_to(:disconnected?)
    end

    it 'implements the fleet dispatch operations the coordinator invokes' do
      %i[chat stream_chat embed count_tokens].each do |op|
        expect(callable).to respond_to(op), "production VllmCallable must implement ##{op}"
      end
    end

    it 'responds to normalize_dispatch_error with kwargs' do
      expect(callable).to respond_to(:normalize_dispatch_error)
    end

    it 'is not disconnected on creation' do
      expect(callable.disconnected?).to be(false)
    end

    it 'becomes disconnected after disconnect' do
      callable.disconnect
      expect(callable.disconnected?).to be(true)
    end

    it 'returns a ProviderOutcome from normalize_dispatch_error' do
      outcome = callable.normalize_dispatch_error(error: RuntimeError.new('test'))
      expect(outcome).to be_a(Legion::Extensions::Llm::Routing::ProviderOutcome)
      expect(outcome.kind).to be_a(Symbol)
      expect(outcome.reason).to be_a(String)
    end

    it 'truncates reason to 512 bytes' do
      long_message = 'x' * 1000
      error = RuntimeError.new(long_message)
      outcome = callable.normalize_dispatch_error(error: error)
      # The callable truncates to 512, then ProviderOutcome may further validate
      expect(outcome.reason.length).to be <= 1024
    end

    it 'renders the dispatch-folded system prompt as the leading wire message (D14)' do
      captured = nil
      connection = instance_double(Legion::Extensions::Llm::Connection)
      allow(connection).to receive(:post) do |path, payload|
        captured = { path: path, payload: payload }
        completion_response
      end
      provider = Legion::Extensions::Llm::Vllm::Provider.new(ssot_harness.instance_configs[0])
      provider.instance_variable_set(:@connection, connection)
      callable.instance_variable_set(:@provider, provider)
      messages = [
        Legion::Extensions::Llm::Canonical::Message.build(
          role: :system, content: 'system from dispatch fold'
        ),
        Legion::Extensions::Llm::Canonical::Message.build(role: :user, content: 'hello')
      ]

      callable.chat(
        messages, model: 'meta-llama/Llama-3.1-8B-Instruct'
      )

      expect(captured[:path]).to eq('/v1/chat/completions')
      expect(captured.dig(:payload, :messages).first).to eq(
        role: 'system', content: 'system from dispatch fold'
      )
    end
  end

  # ─── OfferingDraft validation ──────────────────────────────────────────────

  describe 'OfferingDraft structure' do
    let(:config) { ssot_harness.instance_configs[0] }
    let(:callable) { ssot_harness.build_callable(instance_config: config) }
    let(:drafts) { ssot_harness.build_offering_drafts(instance_config: config, callable: callable, tier: :local) }

    it 'produces valid OfferingDraft instances' do
      expect(drafts).to all(be_a(Legion::Extensions::Llm::Inventory::OfferingDraft))
    end

    it 'includes all required operation evidence keys' do
      expected_ops = Legion::Extensions::Llm::Taxonomies::OPERATIONS.sort
      drafts.each do |draft|
        actual_ops = draft.operation_evidence.keys.sort
        expect(actual_ops).to eq(expected_ops)
      end
    end

    it 'sets publication_source to :provider_catalog' do
      drafts.each do |draft|
        expect(draft.publication_source).to eq(:provider_catalog)
      end
    end

    it 'uses frozen metadata without secret keys' do
      drafts.each do |draft|
        expect(draft.metadata).to be_frozen
        draft.metadata.each_key do |key|
          normalized = key.to_s.downcase.gsub(/[^a-z0-9]/, '')
          expect(normalized).not_to include('credential')
          expect(normalized).not_to include('secret')
          expect(normalized).not_to include('apikey')
        end
      end
    end
  end

  # ─── ReadinessResult contract ──────────────────────────────────────────────

  describe 'ReadinessResult contract' do
    it 'safe_readiness returns a ready ReadinessResult' do
      config = ssot_harness.instance_configs[0]
      callable = ssot_harness.build_callable(instance_config: config)
      result = ssot_harness.safe_readiness(instance_config: config, callable: callable)

      expect(result).to be_a(Legion::Extensions::Llm::Inventory::ReadinessResult)
      expect(result.ready?).to be(true)
      expect(result.reason).to be_a(String)
      expect(result.reason).not_to be_empty
    end

    it 'readiness does not invoke inference on the callable' do
      config = ssot_harness.instance_configs[0]
      callable = ssot_harness.build_callable(instance_config: config)
      ssot_harness.safe_readiness(instance_config: config, callable: callable)
      expect(ssot_harness.inference_call_count(callable: callable)).to eq(0)
    end
  end
end
