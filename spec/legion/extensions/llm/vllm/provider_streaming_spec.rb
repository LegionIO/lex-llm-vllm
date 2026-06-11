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
  end
end
