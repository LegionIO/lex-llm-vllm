# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Legion::Extensions::Llm::Vllm::Translator do
  subject(:translator) { described_class.new }

  let(:config_translator) { described_class.new(config: { enable_thinking: true }) }
  let(:canonical) { Legion::Extensions::Llm::Canonical }

  it_behaves_like 'a canonical provider translator', described_class

  describe '#capabilities' do
    it 'declares provider as vllm' do
      expect(translator.capabilities[:provider]).to eq('vllm')
    end

    it 'declares wire format as openai_compatible' do
      expect(translator.capabilities[:wire_format]).to eq('openai_compatible')
    end

    it 'declares tool_calls_as_text quirk' do
      expect(translator.capabilities[:tool_calls_as_text]).to be true
    end

    it 'declares forced_tool_choice quirk' do
      expect(translator.capabilities[:forced_tool_choice]).to be true
    end

    it 'declares thinking tags' do
      expect(translator.capabilities[:thinking_tags]).to include('think', 'thinking')
    end
  end

  describe '#render_request' do
    it 'includes model from metadata' do
      req = canonical::Request.build(messages: [], metadata: { model: 'my-vllm-model' })
      expect(translator.render_request(req)[:model]).to eq('my-vllm-model')
    end

    it 'renders system prompt as first system message' do
      conformance = Canonical::Conformance
      req = canonical::Request.from_hash(conformance.fixture_symbolized('canonical_system_prompt_request'))
      wire = translator.render_request(req)
      expect(wire[:messages].first[:role]).to eq('system')
    end

    it 'renders tools in OpenAI function format' do
      conformance = Canonical::Conformance
      req = canonical::Request.from_hash(conformance.fixture_symbolized('canonical_tools_request'))
      wire = translator.render_request(req)
      expect(wire[:tools]).to be_an(Array)
      expect(wire[:tools].first[:function][:name]).to eq('get_weather')
    end

    it 'maps G18 params to wire format' do
      conformance = Canonical::Conformance
      req = canonical::Request.from_hash(conformance.fixture_symbolized('canonical_params_mapping_request'))
      wire = translator.render_request(req)

      expect(wire[:max_tokens]).to eq(2048)
      expect(wire[:temperature]).to eq(0.7)
      expect(wire[:stop]).to be_an(Array)
      expect(wire[:stop].first).to eq('[END]')
      expect(wire[:seed]).to eq(42)
    end

    it 'enables thinking via chat_template_kwargs when config has enable_thinking' do
      conformance = Canonical::Conformance
      req = canonical::Request.from_hash(conformance.fixture_symbolized('canonical_thinking_request'))
      expect(config_translator.render_request(req)[:chat_template_kwargs]).to eq(enable_thinking: true)
    end

    it 'renders tool_choice as named function for explicit choice' do
      conformance = Canonical::Conformance
      base = conformance.fixture_symbolized('canonical_tools_request')
      fixture = base.merge('tool_choice' => { name: 'get_weather' })
      req = canonical::Request.from_hash(fixture)
      wire = translator.render_request(req)
      expect(wire[:tool_choice]).to eq(type: 'function', function: { name: 'get_weather' })
    end

    it 'requests streaming token usage via stream_options.include_usage when streaming' do
      req = canonical::Request.build(messages: [], stream: true, metadata: { model: 'm' })
      expect(translator.render_request(req)[:stream_options]).to eq(include_usage: true)
    end

    it 'omits stream_options for non-streaming requests' do
      req = canonical::Request.build(messages: [], stream: false, metadata: { model: 'm' })
      expect(translator.render_request(req)).not_to have_key(:stream_options)
    end

    it 'lets a non-conforming backend opt out via config[:stream_token_usage] = false' do
      opted_out = described_class.new(config: { stream_token_usage: false })
      req = canonical::Request.build(messages: [], stream: true, metadata: { model: 'm' })
      expect(opted_out.render_request(req)).not_to have_key(:stream_options)
    end
  end

  describe '#parse_response' do
    context 'with an OpenAI-compatible simple text response' do
      it 'preserves text and stop_reason' do
        wire = {
          'choices' => [{ 'message' => { 'content' => 'I am fine today' }, 'finish_reason' => 'stop' }],
          'usage' => { 'prompt_tokens' => 12, 'completion_tokens' => 10 },
          'model' => 'vllm-test'
        }
        result = translator.parse_response(wire)
        expect(result).to be_a(canonical::Response)
        expect(result.text).to eq('I am fine today')
        expect(result.stop_reason).to eq(:end_turn)
      end
    end

    context 'with length finish_reason' do
      it 'maps to max_tokens' do
        wire = {
          'choices' => [{ 'message' => { 'content' => '' }, 'finish_reason' => 'length' }],
          'usage' => { 'prompt_tokens' => 12, 'completion_tokens' => 256 }
        }
        expect(translator.parse_response(wire).stop_reason).to eq(:max_tokens)
      end
    end

    context 'with tool call in content but tool_calls field empty' do
      it 'does not synthesize from plain text' do
        wire = {
          'choices' => [{ 'message' => { 'content' => 'Looking up weather for you!' } }],
          'usage' => { 'prompt_tokens' => 12, 'completion_tokens' => 10 }
        }
        result = translator.parse_response(wire)
        expect(result.tool_calls).to be_empty
      end
    end
  end

  describe 'stop_reason mapping' do
    it 'maps stop to end_turn' do
      wire = { 'choices' => [{ 'message' => { 'content' => '' }, 'finish_reason' => 'stop' }] }
      expect(translator.parse_response(wire).stop_reason).to eq(:end_turn)
    end

    it 'maps length to max_tokens' do
      wire = { 'choices' => [{ 'message' => { 'content' => '' }, 'finish_reason' => 'length' }] }
      expect(translator.parse_response(wire).stop_reason).to eq(:max_tokens)
    end
  end
end
