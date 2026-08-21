# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Legion::Extensions::Llm::Vllm::Translator do
  subject(:translator) { described_class.new }

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
    # Build a conformance fixture that always carries a selected model in metadata.
    # §9: the executor selects an exact model before render_request is called; specs
    # must mirror that invariant so the translator's ArgumentError guard is never
    # tripped by missing test data.
    def fixture_with_model(name, model: 'gemma-3-27b')
      base = Canonical::Conformance.fixture_symbolized(name)
      base.merge(metadata: { model: model })
    end

    it 'includes model from metadata' do
      req = canonical::Request.build(messages: [], metadata: { model: 'my-vllm-model' })
      expect(translator.render_request(req)[:model]).to eq('my-vllm-model')
    end

    it 'renders system prompt as first system message' do
      req = canonical::Request.from_hash(fixture_with_model('canonical_system_prompt_request'))
      wire = translator.render_request(req)
      expect(wire[:messages].first[:role]).to eq('system')
    end

    it 'renders tools in OpenAI function format' do
      req = canonical::Request.from_hash(fixture_with_model('canonical_tools_request'))
      wire = translator.render_request(req)
      expect(wire[:tools]).to be_an(Array)
      expect(wire[:tools].first[:function][:name]).to eq('get_weather')
    end

    it 'maps G18 params to wire format' do
      req = canonical::Request.from_hash(fixture_with_model('canonical_params_mapping_request'))
      wire = translator.render_request(req)

      expect(wire[:max_tokens]).to eq(2048)
      expect(wire[:temperature]).to eq(0.7)
      expect(wire[:stop]).to be_an(Array)
      expect(wire[:stop].first).to eq('[END]')
      expect(wire[:seed]).to eq(42)
    end

    # V2: the canonical request is the SOLE thinking authority — a plain
    # translator (no config dial) renders thinking for a request that asks
    # for it, carrying the resolved budget via the chat template.
    it 'renders thinking from the canonical request via chat_template_kwargs' do
      req = canonical::Request.from_hash(fixture_with_model('canonical_thinking_request'))
      expect(translator.render_request(req)[:chat_template_kwargs]).to eq(enable_thinking: true, thinking_budget: 4096)
    end

    # V2: a silent canonical request renders a silent wire — the per-instance
    # config dial no longer forks identical requests across instances.
    it 'renders no thinking kwargs when the canonical request is silent' do
      req = canonical::Request.build(messages: [], metadata: { model: 'm' })
      expect(translator.render_request(req)).not_to have_key(:chat_template_kwargs)
    end

    it 'renders tool_choice as named function for explicit choice' do
      fixture = fixture_with_model('canonical_tools_request').merge('tool_choice' => { name: 'get_weather' })
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

    # V1: the parse side of thinking was untested — the strict factory
    # (Canonical::Thinking.build) must construct valid data for the
    # Qwen-style reasoning wire, with or without a signature.
    context 'with reasoning_content metadata (Qwen-style thinking wire)' do
      it 'builds a Canonical::Thinking with content and nil signature' do
        wire = {
          'choices' => [{
            'message' => { 'content' => 'The answer is 42.', 'reasoning_content' => 'Let me work it out.' },
            'finish_reason' => 'stop'
          }],
          'usage' => { 'prompt_tokens' => 5, 'completion_tokens' => 20 },
          'model' => 'qwen3.6-27b'
        }
        result = translator.parse_response(wire)

        expect(result.text).to eq('The answer is 42.')
        expect(result.thinking).to be_a(canonical::Thinking)
        expect(result.thinking.content).to eq('Let me work it out.')
        expect(result.thinking.signature).to be_nil
      end

      it 'builds a Canonical::Thinking carrying the wire signature' do
        wire = {
          'choices' => [{
            'message' => {
              'content' => 'The answer is 42.',
              'reasoning_content' => 'Let me work it out.',
              'reasoning_signature' => 'sig-abc'
            },
            'finish_reason' => 'stop'
          }],
          'usage' => { 'prompt_tokens' => 5, 'completion_tokens' => 20 }
        }
        result = translator.parse_response(wire)

        expect(result.thinking.signature).to eq('sig-abc')
      end
    end

    # V4: the declared tool_calls_as_text quirk stays, but a synthesized
    # call with unparseable arguments fails the call (the strict
    # ToolArguments policy) instead of fabricating empty arguments, and no
    # source is stamped (attribution is the executor's fact, not the
    # provider's).
    context 'with a synthesized text tool call (V4)' do
      it 'synthesizes a call with parsed arguments and nil source' do
        wire = {
          'choices' => [{
            'message' => { 'content' => '{"name": "get_weather", "arguments": {"city": "SF"}}' },
            'finish_reason' => 'stop'
          }],
          'usage' => { 'prompt_tokens' => 3, 'completion_tokens' => 8 }
        }
        result = translator.parse_response(wire)

        expect(result.tool_calls.size).to eq(1)
        expect(result.tool_calls.first.name).to eq('get_weather')
        expect(result.tool_calls.first.arguments).to eq(city: 'SF')
        expect(result.tool_calls.first.source).to be_nil
      end

      it 'raises on unparseable synthesized arguments instead of fabricating {}' do
        wire = {
          'choices' => [{
            'message' => { 'content' => '{"name": "get_weather", "arguments": "{not-valid-json"}' },
            'finish_reason' => 'stop'
          }],
          'usage' => { 'prompt_tokens' => 3, 'completion_tokens' => 8 }
        }
        expect { translator.parse_response(wire) }.to raise_error(ArgumentError, /tool call arguments/)
      end
    end

    # V16: a non-completion body is a transport/contract fault — it fails
    # loud instead of completing the call with a successful :error response.
    context 'with a non-completion body (V16)' do
      it 'raises on a non-Hash body' do
        expect { translator.parse_response('not a completion') }
          .to raise_error(ArgumentError, /expected a Hash completion body/)
      end

      it 'raises on a Hash body that carries no choices' do
        expect { translator.parse_response({ 'error' => { 'message' => 'boom' } }) }
          .to raise_error(ArgumentError, /no choices/)
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

    # V9: vLLM's documented in-band failure maps to :error (honest), and an
    # unknown future finish_reason is a contract error — not a silent
    # default to the most benign semantic.
    it 'maps abort to error' do
      wire = { 'choices' => [{ 'message' => { 'content' => '' }, 'finish_reason' => 'abort' }] }
      expect(translator.parse_response(wire).stop_reason).to eq(:error)
    end

    it 'raises on an unmapped finish_reason' do
      wire = { 'choices' => [{ 'message' => { 'content' => '' }, 'finish_reason' => 'safety_stop' }] }
      expect { translator.parse_response(wire) }.to raise_error(ArgumentError, /unmapped finish_reason/)
    end
  end

  describe '#parse_chunk' do
    # V10: canonical-shaped chunks are the explicit conformance edge.
    # (Unknown chunk TYPES pass through by the core's consume-side G20d
    # contract; a malformed MEMBER SHAPE is wiring corruption — under the
    # old debug-log rescue it was silently dropped, now it raises.)
    it 'parses a well-formed canonical chunk' do
      chunk = translator.parse_chunk({ 'type' => 'text_delta', 'delta' => 'hi', 'request_id' => 'r1' })

      expect(chunk).to be_a(canonical::Chunk)
      expect(chunk.type).to eq(:text_delta)
      expect(chunk.delta).to eq('hi')
    end

    it 'raises on a malformed canonical chunk instead of dropping it' do
      expect { translator.parse_chunk({ 'type' => 'text_delta', 'usage' => 'garbage' }) }
        .to raise_error(ArgumentError)
    end
  end
end
