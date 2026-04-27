# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Legion::Extensions::Llm::Vllm do
  let(:provider) { described_class::Provider.new(LexLLM.config) }
  let(:model) { LexLLM::Model::Info.new(id: 'meta-llama/Llama-3.1-8B-Instruct', provider: :vllm) }

  it 'exposes provider defaults with inherited fleet settings' do
    settings = described_class.default_settings

    expect(settings[:provider_family]).to eq(:vllm)
    expect(settings[:fleet]).to include(:enabled)
    expect(settings.dig(:instances, :default, :endpoint)).to eq('http://localhost:8000')
    expect(settings.dig(:instances, :default, :usage, :embedding)).to be true
  end

  it 'registers the LexLLM provider class' do
    expect(LexLLM::Provider.resolve(:vllm)).to eq(described_class::Provider)
  end

  it 'uses the shared OpenAI-compatible provider adapter' do
    expect(described_class::Provider.ancestors).to include(LexLLM::Provider::OpenAICompatible)
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
    message = LexLLM::Message.new(role: :user, content: 'hello')
    payload = provider.send(:render_payload, [message], tools: {}, temperature: 0.2, model: model, stream: false,
                                                        schema: nil, thinking: nil, tool_prefs: nil)

    expect(payload.values_at(:model, :stream, :temperature)).to eq(['meta-llama/Llama-3.1-8B-Instruct', false, 0.2])
    expect(payload[:messages]).to eq([{ role: 'user', content: 'hello' }])
  end

  it 'uses an optional bearer token when configured' do
    original = LexLLM.config.vllm_api_key
    LexLLM.config.vllm_api_key = 'token-abc123'

    expect(provider.headers).to eq('Authorization' => 'Bearer token-abc123')
  ensure
    LexLLM.config.vllm_api_key = original
  end

  def management_urls
    [provider.health_url, provider.version_url, provider.reset_prefix_cache_url, provider.reset_mm_cache_url,
     provider.sleep_url, provider.wake_up_url]
  end
end
