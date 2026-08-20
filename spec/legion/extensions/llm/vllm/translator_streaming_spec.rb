# frozen_string_literal: true

require 'spec_helper'

# Regression specs for the P4 streaming outage: parse_chunk previously called
# ThinkingExtractor.extract_from_content (private_class_method in lex-llm
# >= 0.5.0), raising NoMethodError on every streamed text delta and silently
# killing all vLLM streaming.
RSpec.describe Legion::Extensions::Llm::Vllm::Translator do
  subject(:translator) { described_class.new }

  let(:canonical) { Legion::Extensions::Llm::Canonical }

  describe '#parse_chunk text deltas' do
    it 'parses a text delta without raising' do
      data = { 'id' => 'c1', 'model' => 'qwen',
               'choices' => [{ 'delta' => { 'content' => 'Hello' }, 'finish_reason' => nil }] }

      chunk = nil
      expect { chunk = translator.parse_chunk(data) }.not_to raise_error
      expect(chunk.type).to eq(:text_delta)
      expect(chunk.delta).to eq('Hello')
    end

    it 'preserves leading whitespace in deltas' do
      data = { 'id' => 'c1', 'choices' => [{ 'delta' => { 'content' => ' world' }, 'finish_reason' => nil }] }

      expect(translator.parse_chunk(data).delta).to eq(' world')
    end
  end

  describe '#parse_chunk tool call deltas' do
    it 'keeps the opening fragment id and name' do
      data = { 'id' => 'c1', 'choices' => [{ 'delta' => { 'tool_calls' => [
        { 'id' => 'call_1', 'index' => 0, 'function' => { 'name' => 'weather', 'arguments' => '' } }
      ] }, 'finish_reason' => nil }] }

      chunk = translator.parse_chunk(data)
      expect(chunk.type).to eq(:tool_call_delta)
      # The tool_call member is the delta fragment (Hash) — the documented
      # 0.8.0 Chunk shape; a full Canonical::ToolCall is wrong here.
      expect(chunk.tool_call).to be_a(Hash)
      expect(chunk.tool_call[:id]).to eq('call_1')
      expect(chunk.tool_call[:name]).to eq('weather')
    end

    it 'keeps continuation fragments with nil id and raw partial arguments' do
      data = { 'id' => 'c1', 'choices' => [{ 'delta' => { 'tool_calls' => [
        { 'index' => 0, 'function' => { 'arguments' => '{"city":"Min' } }
      ] }, 'finish_reason' => nil }] }

      chunk = translator.parse_chunk(data)
      expect(chunk.type).to eq(:tool_call_delta)
      expect(chunk.tool_call[:id]).to be_nil
      expect(chunk.tool_call[:arguments]).to eq('{"city":"Min')
    end

    it 'returns an array of chunks when multiple tool_calls are batched in one delta' do
      data = { 'id' => 'c1', 'model' => 'qwen', 'choices' => [{ 'delta' => { 'tool_calls' => [
        { 'id' => 'call_1', 'index' => 0, 'function' => { 'name' => 'weather', 'arguments' => '{}' } },
        { 'id' => 'call_2', 'index' => 1, 'function' => { 'name' => 'time', 'arguments' => '{}' } }
      ] }, 'finish_reason' => nil }] }
      result = translator.parse_chunk(data)
      expect(result).to be_an(Array).and have_attributes(size: 2)
      expect(result[0].tool_call[:id]).to eq('call_1')
      expect(result[0].tool_call[:name]).to eq('weather')
      expect(result[1].tool_call[:id]).to eq('call_2')
      expect(result[1].tool_call[:name]).to eq('time')
    end
  end

  describe '#parse_chunk batched tool_calls through full streaming path' do
    let(:batched_data) do
      { 'id' => 'c1', 'model' => 'qwen', 'choices' => [{ 'delta' => { 'tool_calls' => [
        { 'id' => 'call_a', 'index' => 0, 'function' => { 'name' => 'search', 'arguments' => '{"q":"hi"}' } },
        { 'id' => 'call_b', 'index' => 1, 'function' => { 'name' => 'fetch', 'arguments' => '{"url":"x"}' } }
      ] }, 'finish_reason' => 'tool_calls' }] }
    end

    it 'assembles both tool calls when batched delta flows through provider build_chunk' do
      provider = Legion::Extensions::Llm::Vllm::Provider.allocate
      result = provider.send(:build_chunk, batched_data)
      expect(result).to be_an(Array)

      accumulator = Legion::Extensions::Llm::StreamAccumulator.new
      result.each { |chunk| accumulator.add(chunk) }
      response = accumulator.to_response(model: nil)

      expect(response).to be_a(Legion::Extensions::Llm::Canonical::Response)
      expect(response.tool_calls.map(&:id)).to contain_exactly('call_a', 'call_b')
      expect(response.tool_calls.find { |tc| tc.id == 'call_a' }.name).to eq('search')
      expect(response.tool_calls.find { |tc| tc.id == 'call_b' }.name).to eq('fetch')
      expect(response.stop_reason).to eq(:tool_use)
    end
  end
end
