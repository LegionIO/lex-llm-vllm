# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Legion::Extensions::Llm::Vllm do
  let(:provider) { described_class::Provider.new(Legion::Extensions::Llm.config) }
  let(:model) { Legion::Extensions::Llm::Model::Info.new(id: 'meta-llama/Llama-3.1-8B-Instruct', provider: :vllm) }
  let(:registry_publisher) { instance_double(described_class::RegistryPublisher) }

  it 'exposes provider defaults with inherited fleet settings' do
    settings = described_class.default_settings

    expect(settings[:provider_family]).to eq(:vllm)
    expect(settings[:fleet]).to include(:enabled)
    expect(settings.dig(:instances, :default, :endpoint)).to eq('http://localhost:8000')
    expect(settings.dig(:instances, :default, :usage, :embedding)).to be true
  end

  it 'registers the Legion::Extensions::Llm provider class' do
    expect(Legion::Extensions::Llm::Provider.resolve(:vllm)).to eq(described_class::Provider)
  end

  it 'uses the shared OpenAI-compatible provider adapter' do
    expect(described_class::Provider.ancestors).to include(Legion::Extensions::Llm::Provider::OpenAICompatible)
  end

  it 'exposes OpenAI-compatible base endpoint helpers' do
    expect([provider.api_base, provider.completion_url, provider.models_url, provider.embedding_url])
      .to eq(['http://localhost:8000', '/v1/chat/completions', '/v1/models', '/v1/embeddings'])
  end

  it 'exposes vLLM management endpoint helpers' do
    expect(management_urls).to eq(['/health', '/version', '/reset_prefix_cache', '/reset_mm_cache', '/sleep',
                                   '/wake_up'])
  end

  it 'renders chat payloads through the shared OpenAI-compatible adapter' do
    message = Legion::Extensions::Llm::Message.new(role: :user, content: 'hello')
    payload = provider.send(:render_payload, [message], tools: {}, temperature: 0.2, model: model, stream: false,
                                                        schema: nil, thinking: nil, tool_prefs: nil)

    expect(payload.values_at(:model, :stream, :temperature)).to eq(['meta-llama/Llama-3.1-8B-Instruct', false, 0.2])
    expect(payload[:messages]).to eq([{ role: 'user', content: 'hello' }])
  end

  it 'uses an optional bearer token when configured' do
    original = Legion::Extensions::Llm.config.vllm_api_key
    Legion::Extensions::Llm.config.vllm_api_key = 'token-abc123'

    expect(provider.headers).to eq('Authorization' => 'Bearer token-abc123')
  ensure
    Legion::Extensions::Llm.config.vllm_api_key = original
  end

  it 'maps discovered models to explicit OpenAI-compatible routing metadata' do
    models = provider.send(:parse_list_models_response, fake_response(models_body), :vllm,
                           described_class::Provider.capabilities)

    expect(models.first.capabilities).to eq(%w[streaming function_calling vision embeddings])
    expect(models.first.modalities.to_h).to eq(input: %w[text image], output: ['text'])
  end

  it 'publishes live readiness metadata asynchronously through the registry publisher' do
    allow(described_class::Provider).to receive(:registry_publisher).and_return(registry_publisher)
    allow(provider.connection).to receive(:get).with('/health').and_return(fake_response({}))
    allow(registry_publisher).to receive(:publish_readiness_async)

    readiness = provider.readiness(live: true)

    expect(registry_publisher).to have_received(:publish_readiness_async).with(readiness)
  end

  it 'publishes discovered models asynchronously through the registry publisher' do
    stub_registry_publisher
    stub_model_discovery

    models = provider.list_models

    expect(registry_publisher).to have_received(:publish_models_async)
      .with(models, readiness: hash_including(provider: :vllm, live: false))
  end

  it 'builds sanitized lex-llm registry events for vLLM model availability' do
    events = capture_registry_events([model], readiness: { ready: true })

    expect(events.first.to_h).to include(event_type: :offering_available)
    expect(events.first.to_h.dig(:offering, :provider_family)).to eq(:vllm)
    expect(events.first.to_h.dig(:offering, :model)).to eq('meta-llama/Llama-3.1-8B-Instruct')
  end

  def management_urls
    [provider.health_url, provider.version_url, provider.reset_prefix_cache_url, provider.reset_mm_cache_url,
     provider.sleep_url, provider.wake_up_url]
  end

  def models_body
    { 'data' => [{ 'id' => 'meta-llama/Llama-3.1-8B-Instruct', 'created' => 1 }] }
  end

  def fake_response(body)
    Struct.new(:body).new(body)
  end

  def stub_model_discovery
    allow(provider.connection).to receive(:get).with('/v1/models').and_return(fake_response(models_body))
  end

  def stub_registry_publisher
    allow(described_class::Provider).to receive(:registry_publisher).and_return(registry_publisher)
    allow(registry_publisher).to receive(:publish_models_async)
  end

  def capture_registry_events(models, readiness:)
    publisher = described_class::RegistryPublisher.new
    events = []
    allow(publisher).to receive(:publishing_available?).and_return(true)
    allow(publisher).to receive(:publish_event) { |event| events << event }
    allow(Thread).to receive(:new).and_yield
    publisher.publish_models_async(models, readiness:)
    events
  end
end
