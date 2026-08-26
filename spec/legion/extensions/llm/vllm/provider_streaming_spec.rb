# frozen_string_literal: true

require 'spec_helper'
require 'legion/extensions/llm/vllm/provider'

# End-to-end Path A regression specs: SSE data hash -> build_chunk ->
# Canonical::Chunk -> StreamAccumulator#to_response must assemble a
# Canonical::Response (0.8.0: the legacy Chunk bridge is deleted; parse is
# asserted BY TYPE per kit group B2).
RSpec.describe Legion::Extensions::Llm::Vllm::Provider do
  subject(:provider) { described_class.allocate }

  describe '#build_chunk' do
    let(:open_data) do
      { 'id' => 'c1', 'model' => 'qwen', 'choices' => [{ 'delta' => { 'tool_calls' => [
        { 'id' => 'call_1', 'index' => 0, 'function' => { 'name' => 'weather', 'arguments' => '' } }
      ] }, 'finish_reason' => nil }] }
    end

    let(:frag_data) do
      { 'id' => 'c1', 'model' => 'qwen', 'choices' => [{ 'delta' => { 'tool_calls' => [
        { 'index' => 0, 'function' => { 'arguments' => '{"city":"Rio"}' } }
      ] }, 'finish_reason' => nil }] }
    end

    it 'converts a text delta into a Canonical::Chunk that the accumulator assembles' do
      data = { 'id' => 'c1', 'model' => 'qwen',
               'choices' => [{ 'delta' => { 'content' => 'Hello' }, 'finish_reason' => nil }] }

      chunk = provider.send(:build_chunk, data)
      expect(chunk).to be_a(Legion::Extensions::Llm::Canonical::Chunk)
      expect(chunk.type).to eq(:text_delta)
      expect(chunk.delta).to eq('Hello')

      accumulator = Legion::Extensions::Llm::StreamAccumulator.new
      accumulator.add(chunk)
      response = accumulator.to_response(model: nil)
      expect(response).to be_a(Legion::Extensions::Llm::Canonical::Response)
      expect(response.text).to eq('Hello')
    end

    it 'carries tool_call deltas instead of dropping them' do
      accumulator = Legion::Extensions::Llm::StreamAccumulator.new
      [open_data, frag_data].each do |data|
        chunk = provider.send(:build_chunk, data)
        expect(chunk).to be_a(Legion::Extensions::Llm::Canonical::Chunk)
        expect(chunk.type).to eq(:tool_call_delta)
        expect(chunk.tool_call).not_to be_nil
        accumulator.add(chunk)
      end

      response = accumulator.to_response(model: nil)
      expect(response.tool_calls.size).to eq(1)
      expect(response.tool_calls.first).to be_a(Legion::Extensions::Llm::Canonical::ToolCall)
      expect(response.tool_calls.first.id).to eq('call_1')
      expect(response.tool_calls.first.name).to eq('weather')
      expect(response.tool_calls.first.arguments).to eq('city' => 'Rio')
    end

    it 'returns nil for role-only deltas' do
      data = { 'id' => 'c1', 'choices' => [{ 'delta' => { 'role' => 'assistant' }, 'finish_reason' => nil }] }
      expect(provider.send(:build_chunk, data)).to be_nil
    end

    context 'with stop_reason propagation through the canonical chunk path' do
      it 'propagates finish_reason=length as :max_tokens through to the assembled response' do
        content_data = { 'id' => 'c1', 'model' => 'qwen',
                         'choices' => [{ 'delta' => { 'content' => 'truncated output' },
                                         'finish_reason' => 'length' }] }

        chunk = provider.send(:build_chunk, content_data)
        expect(chunk).to be_a(Legion::Extensions::Llm::Canonical::Chunk)
        expect(chunk.stop_reason).to eq(:max_tokens)

        accumulator = Legion::Extensions::Llm::StreamAccumulator.new
        accumulator.add(chunk)
        expect(accumulator.to_response(model: nil).stop_reason).to eq(:max_tokens)
      end

      it 'propagates finish_reason=content_filter through to the assembled response' do
        content_data = { 'id' => 'c1', 'model' => 'qwen',
                         'choices' => [{ 'delta' => { 'content' => '' },
                                         'finish_reason' => 'content_filter' }] }

        chunk = provider.send(:build_chunk, content_data)
        expect(chunk).to be_a(Legion::Extensions::Llm::Canonical::Chunk)
        expect(chunk.stop_reason).to eq(:content_filter)

        accumulator = Legion::Extensions::Llm::StreamAccumulator.new
        accumulator.add(chunk)
        expect(accumulator.to_response(model: nil).stop_reason).to eq(:content_filter)
      end

      it 'propagates finish_reason=tool_calls as :tool_use through to the assembled response' do
        tool_data = { 'id' => 'c1', 'model' => 'qwen',
                      'choices' => [{ 'delta' => { 'tool_calls' => [
                        { 'id' => 'call_99', 'index' => 0,
                          'function' => { 'name' => 'search', 'arguments' => '{}' } }
                      ] }, 'finish_reason' => 'tool_calls' }] }
        chunk = provider.send(:build_chunk, tool_data)
        expect(chunk.stop_reason).to eq(:tool_use)

        accumulator = Legion::Extensions::Llm::StreamAccumulator.new
        accumulator.add(chunk)
        expect(accumulator.to_response(model: nil).stop_reason).to eq(:tool_use)
      end

      it 'propagates finish_reason=stop as :end_turn (a clean stop) through to the assembled response' do
        content_data = { 'id' => 'c1', 'model' => 'qwen',
                         'choices' => [{ 'delta' => { 'content' => '.' },
                                         'finish_reason' => 'stop' }] }

        chunk = provider.send(:build_chunk, content_data)
        expect(chunk).to be_a(Legion::Extensions::Llm::Canonical::Chunk)
        expect(chunk.stop_reason).to eq(:end_turn)

        accumulator = Legion::Extensions::Llm::StreamAccumulator.new
        accumulator.add(chunk)
        expect(accumulator.to_response(model: nil).stop_reason).to eq(:end_turn)
      end

      it 'handles done chunk (empty delta + finish_reason) propagating stop_reason without usage' do
        done_data = { 'id' => 'c1', 'model' => 'qwen',
                      'choices' => [{ 'delta' => {}, 'finish_reason' => 'length' }] }

        chunk = provider.send(:build_chunk, done_data)
        expect(chunk).to be_a(Legion::Extensions::Llm::Canonical::Chunk)
        expect(chunk.type).to eq(:done)
        expect(chunk.stop_reason).to eq(:max_tokens)
        expect(chunk.usage).to be_nil

        accumulator = Legion::Extensions::Llm::StreamAccumulator.new
        accumulator.add(chunk)
        expect(accumulator.stop_reason).to eq(:max_tokens)
      end
    end
  end
end
