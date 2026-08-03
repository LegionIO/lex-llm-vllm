# frozen_string_literal: true

require 'spec_helper'
require 'legion/extensions/llm/vllm/provider'

# End-to-end Path A regression specs: SSE data hash -> build_chunk ->
# legacy Chunk -> StreamAccumulator#filtered_chunk must yield deltas.
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

    it 'converts a text delta into a legacy chunk that survives the accumulator filter' do
      data = { 'id' => 'c1', 'model' => 'qwen',
               'choices' => [{ 'delta' => { 'content' => 'Hello' }, 'finish_reason' => nil }] }

      chunk = provider.send(:build_chunk, data)
      expect(chunk).to be_a(Legion::Extensions::Llm::Chunk)
      expect(chunk.content.to_s).to eq('Hello')

      accumulator = Legion::Extensions::Llm::StreamAccumulator.new
      accumulator.add(chunk)
      expect(accumulator.filtered_chunk(chunk)).not_to be_nil
    end

    it 'carries tool_call deltas instead of dropping them' do
      accumulator = Legion::Extensions::Llm::StreamAccumulator.new
      [open_data, frag_data].each do |data|
        chunk = provider.send(:build_chunk, data)
        expect(chunk.tool_calls).not_to be_nil
        accumulator.add(chunk)
      end

      message = accumulator.to_message(nil)
      expect(message.tool_calls.keys).to eq(['call_1'])
      expect(message.tool_calls['call_1'].name).to eq('weather')
      expect(message.tool_calls['call_1'].arguments).to eq({ 'city' => 'Rio' })
    end

    it 'returns nil for role-only deltas' do
      data = { 'id' => 'c1', 'choices' => [{ 'delta' => { 'role' => 'assistant' }, 'finish_reason' => nil }] }
      expect(provider.send(:build_chunk, data)).to be_nil
    end

    context 'with stop_reason propagation through legacy chunk bridge' do
      it 'propagates finish_reason=length as :max_tokens through to the assembled Message' do
        content_data = { 'id' => 'c1', 'model' => 'qwen',
                         'choices' => [{ 'delta' => { 'content' => 'truncated output' },
                                         'finish_reason' => 'length' }] }

        chunk = provider.send(:build_chunk, content_data)
        expect(chunk).to be_a(Legion::Extensions::Llm::Chunk)
        expect(chunk.stop_reason).to eq(:max_tokens)

        accumulator = Legion::Extensions::Llm::StreamAccumulator.new
        accumulator.add(chunk)
        message = accumulator.to_message(nil)
        expect(message.stop_reason).to eq(:max_tokens)
      end

      it 'propagates finish_reason=content_filter through to the assembled Message' do
        content_data = { 'id' => 'c1', 'model' => 'qwen',
                         'choices' => [{ 'delta' => { 'content' => '' },
                                         'finish_reason' => 'content_filter' }] }

        chunk = provider.send(:build_chunk, content_data)
        expect(chunk).to be_a(Legion::Extensions::Llm::Chunk)
        expect(chunk.stop_reason).to eq(:content_filter)

        accumulator = Legion::Extensions::Llm::StreamAccumulator.new
        accumulator.add(chunk)
        message = accumulator.to_message(nil)
        expect(message.stop_reason).to eq(:content_filter)
      end

      it 'propagates finish_reason=tool_calls as :tool_use through to the assembled Message' do
        tool_data = { 'id' => 'c1', 'model' => 'qwen',
                      'choices' => [{ 'delta' => { 'tool_calls' => [
                        { 'id' => 'call_99', 'index' => 0,
                          'function' => { 'name' => 'search', 'arguments' => '{}' } }
                      ] }, 'finish_reason' => 'tool_calls' }] }
        chunk = provider.send(:build_chunk, tool_data)
        expect(chunk.stop_reason).to eq(:tool_use)

        accumulator = Legion::Extensions::Llm::StreamAccumulator.new
        accumulator.add(chunk)
        expect(accumulator.to_message(nil).stop_reason).to eq(:tool_use)
      end

      it 'propagates finish_reason=stop as :end_turn (a clean stop) through to the assembled Message' do
        content_data = { 'id' => 'c1', 'model' => 'qwen',
                         'choices' => [{ 'delta' => { 'content' => '.' },
                                         'finish_reason' => 'stop' }] }

        chunk = provider.send(:build_chunk, content_data)
        expect(chunk).to be_a(Legion::Extensions::Llm::Chunk)
        expect(chunk.stop_reason).to eq(:end_turn)

        accumulator = Legion::Extensions::Llm::StreamAccumulator.new
        accumulator.add(chunk)
        message = accumulator.to_message(nil)
        expect(message.stop_reason).to eq(:end_turn)
      end

      it 'handles done chunk (empty delta + finish_reason) propagating stop_reason' do
        done_data = { 'id' => 'c1', 'model' => 'qwen',
                      'choices' => [{ 'delta' => {}, 'finish_reason' => 'length' }] }

        chunk = provider.send(:build_chunk, done_data)
        expect(chunk).to be_a(Legion::Extensions::Llm::Chunk)
        expect(chunk.stop_reason).to eq(:max_tokens)

        accumulator = Legion::Extensions::Llm::StreamAccumulator.new
        accumulator.add(chunk)
        expect(accumulator.stop_reason).to eq(:max_tokens)
      end
    end
  end
end
