# frozen_string_literal: true

require 'spec_helper'
require 'legion/extensions/llm/vllm/runners/discovery'

RSpec.describe Legion::Extensions::Llm::Vllm do
  # V6: a provider is only executable with its OWN explicit endpoint —
  # the test provider carries one, as every production instance config does.
  let(:provider) { described_class::Provider.new(vllm_api_base: 'http://localhost:8000') }
  let(:model) { 'meta-llama/Llama-3.1-8B-Instruct' }

  it 'exposes simple provider defaults' do
    settings = described_class.default_settings
    instance = settings.dig(:instances, :default)

    expect(settings[:enabled]).to be true
    expect(settings[:provider_family]).to eq(:vllm)
    expect(instance[:endpoint]).to eq('http://localhost:8000')
    expect(instance.dig(:fleet, :respond_to_requests)).to be false
  end

  # V2: no enable_thinking default ships — a shipped config dial is a second
  # thinking authority (it would execute thinking the canonical request did
  # not ask for) and contradicts the :unknown thinking publication.
  it 'ships no enable_thinking default in the instance template' do
    instance = described_class.default_settings.dig(:instances, :default)

    expect(instance).not_to have_key(:enable_thinking)
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

  it 'renders chat payloads from canonical values through the vLLM dialect translator' do
    message = Legion::Extensions::Llm::Canonical::Message.build(role: :user, content: 'hello')
    params = Legion::Extensions::Llm::Canonical::Params.build(temperature: 0.2)

    payload = provider.send(:render_payload, [message], tools: {}, params: params, model: model, stream: false,
                                                        schema: nil, thinking: nil, tool_prefs: nil)

    expect(payload.values_at(:model, :stream, :temperature)).to eq(['meta-llama/Llama-3.1-8B-Instruct', false, 0.2])
    expect(payload[:messages]).to eq([{ role: 'user', content: 'hello' }])
  end

  # V2: the instance config is no longer a thinking authority — a silent
  # canonical request renders a silent wire even on a config that sets
  # enable_thinking (the dial no longer exists; the key is inert).
  it 'renders no thinking kwargs for a silent canonical request regardless of config' do
    configured = described_class::Provider.new(vllm_api_base: 'http://localhost:8000', enable_thinking: true)
    message = Legion::Extensions::Llm::Canonical::Message.build(role: :user, content: 'hello')

    payload = configured.send(:render_payload, [message], tools: {}, params: nil, model: model, stream: false,
                                                          schema: nil, thinking: nil, tool_prefs: nil)

    expect(payload).not_to have_key(:chat_template_kwargs)
  end

  # V6: an endpoint-less instance is unexecutable — construction fails
  # through the base ensure_configured! contract; no localhost or
  # sibling-endpoint fallback exists.
  it 'raises at construction when the instance has no explicit endpoint' do
    expect { described_class::Provider.new(tier: :local) }
      .to raise_error(Legion::Extensions::Llm::ConfigurationError, /vllm_api_base/)
  end

  it 'uses an optional bearer token when configured' do
    tokened = described_class::Provider.new(vllm_api_base: 'http://localhost:8000', vllm_api_key: 'token-abc123')

    expect(tokened.headers).to eq('Authorization' => 'Bearer token-abc123')
  end

  # V15: a block-shaped system prompt is not representable on the vLLM
  # dialect — it fails at the edge instead of vanishing.
  it 'raises when the system message content is not a plain String' do
    system_blocks = Legion::Extensions::Llm::Canonical::Message.build(
      role: :system, content: [{ type: 'text', text: 'be brief' }]
    )
    user = Legion::Extensions::Llm::Canonical::Message.build(role: :user, content: 'hello')
    model = 'gemma-4-31b-it'

    expect do
      provider.send(:render_payload, [system_blocks, user], tools: {}, params: nil, model: model, stream: false, schema: nil, thinking: nil, tool_prefs: nil)
    end.to raise_error(ArgumentError, /system prompt must be a plain String/)
  end

  # 0.8.0 (07 C5): the legacy ModelOffering production path is deleted — the
  # per-gem writer (Runners::Discovery, the shared Discovery::Pipeline)
  # publishes OfferingDrafts; the base read path serves the activated
  # inventory offerings for this instance from the registry snapshot.

  it 'serves the activated inventory offerings for the instance from the registry snapshot (07 C5)' do
    key = Legion::Extensions::Llm::Inventory::Identity::InstanceKey.new(
      provider_family: :vllm, instance_id: 'default'
    )
    publisher = Legion::Extensions::Llm::Inventory::Publisher.new(provider_family: :vllm)
    coordinator = Legion::Extensions::Llm::Inventory::ProbeCoordinator.new(instance_key: key, enqueue: ->(**) { true })
    callable = Legion::Extensions::Llm::Vllm::Helpers::Callable.new(
      instance_cfg: { name: 'default', tier: :local }, logger: Logger.new(File::NULL)
    )
    token = publisher.claim_instance(instance_id: 'default', callable: callable, probe_request_handle: coordinator)
    probe = publisher.readiness_probe_started(instance_id: 'default', publisher_token: token)
    draft = described_class::Runners::Discovery.build_offering_draft(
      instance_cfg: { name: 'default', tier: :local }, instance_key: key,
      model_id: 'meta-llama/Llama-3.1-8B-Instruct',
      model_data: { id: 'meta-llama/Llama-3.1-8B-Instruct', max_model_len: 131_072 }
    )
    publisher.activate_instance_snapshot(
      instance_id: 'default', publisher_token: token, offerings: [draft], sequence: 0, probe_token: probe
    )

    offerings = provider.discover_offerings

    expect(offerings.size).to eq(1)
    expect(offerings.first.model).to eq('meta-llama/Llama-3.1-8B-Instruct')
    expect(offerings.first.instance_key.instance_id).to eq('default')
  ensure
    Legion::Extensions::Llm::Inventory::Registry.reset!
  end

  # H5 (0.8.0): the offerings read path performs NO transport — it is an
  # in-memory snapshot lookup, and `live:` is accepted for signature
  # compatibility only.
  it 'performs no transport on offerings reads, even with live: true' do
    connection = instance_spy(Legion::Extensions::Llm::Connection)
    allow(provider).to receive(:connection).and_return(connection)

    expect { provider.discover_offerings(live: true) }.not_to raise_error
    expect(connection).not_to have_received(:get)
    expect(connection).not_to have_received(:post)
  end

  it 'filters snapshot offerings by model and instance keys' do
    key = Legion::Extensions::Llm::Inventory::Identity::InstanceKey.new(
      provider_family: :vllm, instance_id: 'default'
    )
    publisher = Legion::Extensions::Llm::Inventory::Publisher.new(provider_family: :vllm)
    coordinator = Legion::Extensions::Llm::Inventory::ProbeCoordinator.new(instance_key: key, enqueue: ->(**) { true })
    callable = Legion::Extensions::Llm::Vllm::Helpers::Callable.new(
      instance_cfg: { name: 'default', tier: :local }, logger: Logger.new(File::NULL)
    )
    token = publisher.claim_instance(instance_id: 'default', callable: callable, probe_request_handle: coordinator)
    probe = publisher.readiness_probe_started(instance_id: 'default', publisher_token: token)
    draft = described_class::Runners::Discovery.build_offering_draft(
      instance_cfg: { name: 'default', tier: :local }, instance_key: key,
      model_id: 'meta-llama/Llama-3.1-8B-Instruct',
      model_data: { id: 'meta-llama/Llama-3.1-8B-Instruct', max_model_len: 131_072 }
    )
    publisher.activate_instance_snapshot(
      instance_id: 'default', publisher_token: token, offerings: [draft], sequence: 0, probe_token: probe
    )

    expect(provider.discover_offerings(model: 'meta-llama/Llama-3.1-8B-Instruct')).not_to be_empty
    expect(provider.discover_offerings(model: 'other-model')).to be_empty
    expect(provider.discover_offerings(instance: 'other-instance')).to be_empty
  ensure
    Legion::Extensions::Llm::Inventory::Registry.reset!
  end

  describe '.discover_instances' do
    def stub_vllm_instances(value)
      allow(described_class).to receive(:settings).and_return({ instances: value })
    end

    # V13: NO stub — the module-level settings read resolves through the
    # explicit Legion::Settings::Helper extension to the genuine
    # [:extensions][:llm][:vllm] tree (loader injection is not a dependency).
    it 'resolves settings from the genuine settings tree without stubbing' do
      original_llm = Legion::Settings[:extensions][:llm]
      Legion::Settings[:extensions][:llm] = {
        vllm: { instances: { apollo: { vllm_api_base: 'http://apollo:8000' } } }
      }

      instances = described_class.discover_instances

      expect(instances.keys).to eq([:apollo])
      expect(instances[:apollo]).to include(vllm_api_base: 'http://apollo:8000', tier: :direct)
    ensure
      Legion::Settings[:extensions][:llm] = original_llm
    end

    it 'returns configured instances from extension settings' do
      stub_vllm_instances({ gpu_cluster: { vllm_api_base: 'http://gpu-node:8000' } })
      instances = described_class.discover_instances

      expect(instances[:gpu_cluster]).to eq(vllm_api_base: 'http://gpu-node:8000', tier: :direct,
                                            capabilities: {},
                                            provider_capabilities: { streaming: true })
    end

    it 'normalizes base_url from settings to vllm_api_base' do
      stub_vllm_instances({ apollo: { base_url: 'http://10.11.164.92:8000/v1' } })
      instances = described_class.discover_instances

      expect(instances[:apollo]).to include(vllm_api_base: 'http://10.11.164.92:8000',
                                            tier: :direct)
      expect(instances[:apollo]).not_to have_key(:base_url)
    end

    it 'normalizes endpoint aliases from settings to vllm_api_base' do
      stub_vllm_instances({ apollo: { endpoint: 'http://10.11.164.92:8000/v1' } })
      instances = described_class.discover_instances

      expect(instances[:apollo]).to include(vllm_api_base: 'http://10.11.164.92:8000',
                                            tier: :direct)
      expect(instances[:apollo]).not_to have_key(:endpoint)
    end

    it 'keeps the default instance in the claimable set' do
      stub_vllm_instances(
        default: described_class.default_settings.dig(:instances, :default),
        apollo: { vllm_api_base: 'http://apollo:8000' }
      )

      instances = described_class.discover_instances
      expect(instances.keys).to contain_exactly(:default, :apollo)
      expect(instances[:default]).to include(vllm_api_base: 'http://localhost:8000', tier: :direct)
    end

    it 'keeps a configured :default (values differing from the template) in the claimable set' do
      configured_default = described_class.default_settings
                                          .dig(:instances, :default)
                                          .merge(vllm_api_base: 'http://apollo-001:8000')
      stub_vllm_instances(default: configured_default, apollo: { vllm_api_base: 'http://apollo:8000' })
      instances = described_class.discover_instances

      expect(instances.keys).to contain_exactly(:default, :apollo)
      expect(instances[:default]).to include(vllm_api_base: 'http://apollo-001:8000', tier: :direct)
    end

    # The shared Discovery::Pipeline reads discover_instances as the single
    # claimable source — an operator's enabled: false is a skip, never a claim
    # (a disabled instance would otherwise be claimed + published as a live lane).
    it 'skips instances with enabled: false' do
      stub_vllm_instances(
        apollo: { vllm_api_base: 'http://apollo:8000' },
        off: { vllm_api_base: 'http://off-node:8000', enabled: false }
      )
      instances = described_class.discover_instances

      expect(instances.keys).to eq([:apollo])
      expect(instances).not_to have_key(:off)
    end

    it 'keeps an instance with enabled: true in the claimable set' do
      stub_vllm_instances({ apollo: { vllm_api_base: 'http://apollo:8000', enabled: true } })

      expect(described_class.discover_instances.keys).to eq([:apollo])
    end

    # D3: an entry with no resolvable endpoint is unclaimable — skip it rather
    # than defaulting it to localhost.
    it 'skips entries without a resolvable endpoint' do
      stub_vllm_instances(
        apollo: { vllm_api_base: 'http://apollo:8000' },
        ghost: { tier: :direct }
      )
      instances = described_class.discover_instances

      expect(instances.keys).to eq([:apollo])
    end

    it 'returns empty hash when no instances are configured' do
      stub_vllm_instances({})

      expect(described_class.discover_instances).to eq({})
    end

    it 'ignores settings when the value is not a Hash' do
      stub_vllm_instances('not-a-hash')

      expect(described_class.discover_instances).to eq({})
    end

    it 'preserves explicit tier from configured instance settings' do
      stub_vllm_instances({ edge: { vllm_api_base: 'http://edge-node:8000', tier: :fleet } })
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
end
