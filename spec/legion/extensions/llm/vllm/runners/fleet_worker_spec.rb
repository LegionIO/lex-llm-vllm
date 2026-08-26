# frozen_string_literal: true

require 'spec_helper'
require 'legion/extensions/llm/fleet/provider_responder'
require 'legion/extensions/llm/vllm/runners/fleet_worker'

FleetWorkerSpecDelivery = Class.new unless defined?(FleetWorkerSpecDelivery)
FleetWorkerSpecProperties = Class.new unless defined?(FleetWorkerSpecProperties)

RSpec.describe Legion::Extensions::Llm::Vllm::Runners::FleetWorker do
  let(:payload) { { request_id: 'req-1', provider: 'vllm', provider_instance: 'local' } }
  let(:delivery) { instance_double(FleetWorkerSpecDelivery) }
  let(:properties) { instance_double(FleetWorkerSpecProperties) }

  it 'uses Legion logging helpers for runner logging' do
    expect(described_class.singleton_class.ancestors).to include(Legion::Logging::Helper)
  end

  it 'delegates fleet execution to the shared lex-llm responder helper (exact-only v3 contract)' do
    allow(Legion::Extensions::Llm::Fleet::ProviderResponder).to receive(:call).and_return(:ok)

    # The Subscription dispatch calls `runner_class.send(fn, **message)` — the
    # whole delivered envelope arrives as keyword arguments, never a positional
    # payload. L6: the dead provider_class/provider_instances params are gone —
    # v3 dispatch is exact-only and never constructs a provider.
    result = described_class.handle_fleet_request(**payload, delivery: delivery, properties: properties)

    expect(result).to eq(:ok)
    expect(Legion::Extensions::Llm::Fleet::ProviderResponder).to have_received(:call).with(
      payload: payload,
      provider_family: :vllm,
      registry: Legion::Extensions::Llm::Inventory::Registry,
      delivery: delivery,
      properties: properties
    )
  end
end
