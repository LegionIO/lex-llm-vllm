# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Legion::Extensions::Llm::Vllm do
  let(:provider) { described_class::Provider.new(Legion::Extensions::Llm.config) }
  let(:model) { Legion::Extensions::Llm::Model::Info.new(id: 'meta-llama/Llama-3.1-8B-Instruct', provider: :vllm) }
  let(:registry_publisher) { instance_double(Legion::Extensions::Llm::RegistryPublisher) }

  it 'exposes simple provider defaults with thinking enabled' do
    settings = described_class.default_settings
    instance = settings.dig(:instances, :default)

    expect(settings[:enabled]).to be true
    expect(settings[:provider_family]).to eq(:vllm)
    expect(instance[:endpoint]).to eq('http://localhost:8000')
    expect(instance[:enable_thinking]).to be true
    expect(instance.dig(:fleet, :respond_to_requests)).to be false
  end

  it 'does not register on the deprecated Provider.register registry' do
    expect(Legion::Extensions::Llm::Provider).not_to respond_to(:resolve)
  end

  it 'uses the shared OpenAI-compatible provider adapter' do
    expect(described_class::Provider.ancestors).to include(Legion::Extensions::Llm::Provider::OpenAICompatible)
  end

  it 'uses Legion logging helpers for provider and root logging' do
    expect(described_class.singleton_class.ancestors).to include(Legion::Logging::Helper)
    expect(described_class::Provider.ancestors).to include(Legion::Logging::Helper)
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

  it 'uses provider instance thinking settings when rendering chat payloads' do
    configured = described_class::Provider.new(vllm_api_base: 'http://localhost:8000', enable_thinking: true)
    message = Legion::Extensions::Llm::Message.new(role: :user, content: 'hello')

    payload = configured.send(:render_payload, [message], tools: {}, temperature: 0.2, model: model, stream: false,
                                                          schema: nil, thinking: nil, tool_prefs: nil)

    expect(payload[:chat_template_kwargs]).to eq(enable_thinking: true)
  end

  it 'uses an optional bearer token when configured' do
    original = Legion::Extensions::Llm.config.vllm_api_key
    Legion::Extensions::Llm.config.vllm_api_key = 'token-abc123'

    expect(provider.headers).to eq('Authorization' => 'Bearer token-abc123')
  ensure
    Legion::Extensions::Llm.config.vllm_api_key = original
  end

  it 'maps discovered models with context_length from max_model_len' do
    models = provider.send(:parse_list_models_response, fake_response(models_body), :vllm,
                           described_class::Provider.capabilities)

    expect(models.first.capabilities).to eq([:streaming])
    expect(models.first.context_length).to eq(131_072)
  end

  it 'publishes live readiness metadata asynchronously through the registry publisher' do
    allow(described_class).to receive(:registry_publisher).and_return(registry_publisher)
    allow(provider.connection).to receive(:get).with('/health').and_return(fake_response({}))
    allow(registry_publisher).to receive(:publish_readiness_async)

    readiness = provider.readiness(live: true)

    expect(registry_publisher).to have_received(:publish_readiness_async).with(readiness)
  end

  it 'returns structured provider health for live discovery offerings' do
    allow(provider.connection).to receive(:get).with('/health').and_return(fake_response({}))
    stub_model_discovery

    offering = provider.discover_offerings(live: true).first

    expect(offering.health).to include(provider: :vllm, instance_id: :default)
    expect(offering.health[:raw]).to eq({})
  end

  it 'publishes discovered models asynchronously through the registry publisher' do
    stub_registry_publisher
    stub_model_discovery
    allow(provider).to receive(:health).and_return(provider: :vllm, instance_id: :default, ready: true,
                                                   status: 'healthy', circuit_state: 'closed', raw: {})
    allow(registry_publisher).to receive(:publish_readiness_async)

    provider.discover_offerings(live: true)

    expect(registry_publisher).to have_received(:publish_models_async).at_least(:once)
  end

  it 'does not probe vLLM for uncached non-live offerings reads' do
    allow(provider).to receive(:list_models).and_raise('unexpected live discovery')

    expect(provider.discover_offerings).to eq([])
    expect(provider).not_to have_received(:list_models)
  end

  it 'marks offering discovery failures handled before falling back' do
    error = RuntimeError.new('vllm unavailable')
    allow(provider).to receive(:list_models).and_raise(error)
    allow(provider).to receive(:handle_exception)

    expect(provider.discover_offerings(live: true)).to eq([])
    expect(provider).to have_received(:handle_exception)
      .with(error, level: :warn, handled: true, operation: 'vllm.discover_offerings')
  end

  it 'serves non-live offerings reads from the live discovery cache' do
    allow(provider.connection).to receive(:get).with('/health').and_return(fake_response({}))
    stub_model_discovery
    live_offerings = provider.discover_offerings(live: true)
    allow(provider).to receive(:list_models).and_raise('unexpected live discovery')

    expect(provider.discover_offerings.map(&:model)).to eq(live_offerings.map(&:model))
  end

  it 'uses provider instance transport and tier in discovered offerings' do
    configured = described_class::Provider.new(instance_id: :apollo, transport: :rabbitmq, tier: :fleet)
    offering = configured.send(:offering_from_model, model)

    expect(offering.to_h).to include(instance_id: :apollo, transport: :rabbitmq, tier: :fleet)
  end

  it 'translates instance enable_* flags into offering capabilities' do
    configured = described_class::Provider.new(
      vllm_api_base: 'http://localhost:8000',
      enable_thinking: true,
      enable_tools: true,
      enable_streaming: true
    )
    offering = configured.send(:offering_from_model, model)

    expect(offering.capabilities).to include(:completion, :tools, :thinking, :streaming)
  end

  it 'does not reclassify inference models as embeddings when embedding is not resolved' do
    configured = described_class::Provider.new(
      vllm_api_base: 'http://localhost:8000',
      enable_thinking: true,
      enable_tools: true
    )

    offering = configured.send(:offering_from_model, model)

    expect(offering.usage_type).to eq(:inference)
    expect(offering.capabilities).not_to include(:embedding)
  end

  it 'builds sanitized lex-llm registry events for vLLM model availability' do
    events = capture_registry_events([model], readiness: { ready: true })

    expect(events.first.to_h).to include(event_type: :offering_available)
    expect(events.first.to_h.dig(:offering, :provider_family)).to eq(:vllm)
    expect(events.first.to_h.dig(:offering, :model)).to eq('meta-llama/Llama-3.1-8B-Instruct')
  end

  it 'delegates registry_publisher to the base RegistryPublisher class' do
    publisher = described_class.registry_publisher

    expect(publisher).to be_a(Legion::Extensions::Llm::RegistryPublisher)
    expect(publisher.provider_family).to eq(:vllm)
  end

  describe '.discover_instances' do
    before do
      allow(Legion::Extensions::Llm::CredentialSources).to receive_messages(http_ok?: false, setting: nil)
    end

    it 'returns local instance when vLLM health endpoint is reachable' do
      stub_local_health(true)
      instances = described_class.discover_instances

      expect(instances[:local]).to eq(
        vllm_api_base: 'http://localhost:8000', tier: :local, capabilities: [:completion]
      )
    end

    it 'omits local instance when vLLM health endpoint is unreachable' do
      instances = described_class.discover_instances

      expect(instances).not_to have_key(:local)
    end

    it 'returns configured instances from extension settings' do
      stub_vllm_settings({ gpu_cluster: { vllm_api_base: 'http://gpu-node:8000' } })
      instances = described_class.discover_instances

      expect(instances[:gpu_cluster]).to eq(vllm_api_base: 'http://gpu-node:8000', tier: :direct,
                                            capabilities: {},
                                            provider_capabilities: { streaming: true })
    end

    it 'normalizes base_url from Legion settings to vllm_api_base' do
      stub_vllm_settings({ apollo: { base_url: 'http://10.11.164.92:8000/v1' } })
      instances = described_class.discover_instances

      expect(instances[:apollo]).to include(vllm_api_base: 'http://10.11.164.92:8000',
                                            tier: :direct)
      expect(instances[:apollo]).not_to have_key(:base_url)
    end

    it 'normalizes endpoint aliases from Legion settings to vllm_api_base' do
      stub_vllm_settings({ apollo: { endpoint: 'http://10.11.164.92:8000/v1' } })
      instances = described_class.discover_instances

      expect(instances[:apollo]).to include(vllm_api_base: 'http://10.11.164.92:8000',
                                            tier: :direct)
      expect(instances[:apollo]).not_to have_key(:endpoint)
    end

    it 'returns both local and configured instances when both are available' do
      stub_local_health(true)
      stub_vllm_settings({ remote: { vllm_api_base: 'http://remote:8000' } })
      instances = described_class.discover_instances

      expect(instances.keys).to contain_exactly(:local, :remote)
      expect(instances[:local][:tier]).to eq(:local)
      expect(instances[:remote][:tier]).to eq(:direct)
    end

    it 'returns empty hash when nothing is available' do
      instances = described_class.discover_instances

      expect(instances).to eq({})
    end

    it 'ignores settings when the value is not a Hash' do
      stub_vllm_settings('not-a-hash')

      expect(described_class.discover_instances).to eq({})
    end

    it 'preserves explicit tier from configured instance settings' do
      stub_vllm_settings({ edge: { vllm_api_base: 'http://edge-node:8000', tier: :fleet } })
      instances = described_class.discover_instances

      expect(instances[:edge][:tier]).to eq(:fleet)
    end
  end

  describe '.normalize_instance_config' do
    it 'infers tier :local for a localhost endpoint' do
      result = described_class.normalize_instance_config(vllm_api_base: 'http://localhost:8000')

      expect(result[:tier]).to eq(:local)
    end

    it 'infers tier :direct for a remote IP endpoint' do
      result = described_class.normalize_instance_config(vllm_api_base: 'http://10.0.1.50:8000')

      expect(result[:tier]).to eq(:direct)
    end

    it 'preserves explicit tier :fleet when provided in config' do
      result = described_class.normalize_instance_config(vllm_api_base: 'http://localhost:8000', tier: :fleet)

      expect(result[:tier]).to eq(:fleet)
    end

    it 'logs invalid endpoint tier inference through the helper and falls back to direct' do
      allow(described_class).to receive(:handle_exception)

      result = described_class.normalize_instance_config(vllm_api_base: '://not-a-url')

      expect(result[:tier]).to eq(:direct)
      expect(described_class).to have_received(:handle_exception)
        .with(instance_of(URI::InvalidURIError), level: :warn, handled: true,
                                                 operation: 'vllm.infer_tier_from_endpoint')
    end

    it 'extracts vllm_api_key from credentials hash' do
      result = described_class.normalize_instance_config(
        vllm_api_base: 'http://remote:8000',
        credentials: { api_key: 'secret-token' }
      )

      expect(result[:vllm_api_key]).to eq('secret-token')
      expect(result).not_to have_key(:credentials)
    end

    it 'does not override explicit vllm_api_key with credentials hash' do
      result = described_class.normalize_instance_config(
        vllm_api_base: 'http://remote:8000',
        vllm_api_key: 'explicit-key',
        credentials: { api_key: 'nested-key' }
      )

      expect(result[:vllm_api_key]).to eq('explicit-key')
    end
  end

  def management_urls
    [provider.health_url, provider.version_url, provider.reset_prefix_cache_url, provider.reset_mm_cache_url,
     provider.sleep_url, provider.wake_up_url]
  end

  def models_body
    { 'data' => [{ 'id' => 'meta-llama/Llama-3.1-8B-Instruct', 'created' => 1, 'max_model_len' => 131_072 }] }
  end

  def fake_response(body)
    Struct.new(:body).new(body)
  end

  def stub_model_discovery
    allow(provider.connection).to receive(:get).with('/v1/models').and_return(fake_response(models_body))
  end

  def stub_registry_publisher
    allow(described_class).to receive(:registry_publisher).and_return(registry_publisher)
    allow(registry_publisher).to receive(:publish_models_async)
  end

  def stub_local_health(result)
    allow(Legion::Extensions::Llm::CredentialSources).to receive(:http_ok?)
      .with('http://localhost:8000', path: '/health', timeout: 0.1)
      .and_return(result)
  end

  def stub_vllm_settings(value)
    allow(Legion::Extensions::Llm::CredentialSources).to receive(:setting)
      .with(:extensions, :llm, :vllm, :instances)
      .and_return(value)
  end

  def capture_registry_events(models, readiness:)
    publisher = Legion::Extensions::Llm::RegistryPublisher.new(provider_family: :vllm)
    events = []
    allow(publisher).to receive(:publishing_available?).and_return(true)
    allow(publisher).to receive(:publish_event) { |event| events << event }
    allow(Thread).to receive(:new).and_yield
    publisher.publish_models_async(models, readiness:)
    events
  end

  describe 'CapabilityPolicy integration' do
    let(:bare_model) do
      Legion::Extensions::Llm::Model::Info.from_hash(
        id: 'gemma-4-12b-it', name: 'gemma-4-12b-it', provider: :vllm,
        context_length: 32_768, capabilities: [], metadata: {}
      )
    end

    it 'does not claim tools/vision/embeddings/thinking for a bare model discovery response' do
      offering = provider.send(:offering_from_model, bare_model)

      expect(offering.capabilities).to include(:streaming)
      expect(offering.capabilities).not_to include(:tools)
      expect(offering.capabilities).not_to include(:vision)
      expect(offering.capabilities).not_to include(:embedding)
      expect(offering.capabilities).not_to include(:thinking)
    end

    it 'produces capabilities from instance config with source :instance_override' do
      configured = described_class::Provider.new(
        vllm_api_base: 'http://localhost:8000',
        capabilities: { streaming: true, tools: true, thinking: true }
      )
      offering = configured.send(:offering_from_model, bare_model)

      expect(offering.capabilities).to include(:streaming, :tools, :thinking)
      sources = offering.capability_sources
      expect(sources[:tools][:source]).to eq(:instance_override)
      expect(sources[:thinking][:source]).to eq(:instance_override)
    end

    it 'produces :thinking from enable_thinking alias with source :instance_override' do
      configured = described_class::Provider.new(
        vllm_api_base: 'http://localhost:8000',
        enable_thinking: true
      )
      offering = configured.send(:offering_from_model, bare_model)

      expect(offering.capabilities).to include(:thinking)
      expect(offering.capability_sources[:thinking][:source]).to eq(:instance_override)
    end

    it 'produces capabilities from model-level override with source :model_override' do
      configured = described_class::Provider.new(
        vllm_api_base: 'http://localhost:8000',
        models: { 'gemma-4-12b-it' => { tools_flag: true, thinking_flag: true } }
      )
      offering = configured.send(:offering_from_model, bare_model)

      expect(offering.capabilities).to include(:tools, :thinking)
      expect(offering.capability_sources[:tools][:source]).to eq(:model_override)
      expect(offering.capability_sources[:thinking][:source]).to eq(:model_override)
    end
  end
end
