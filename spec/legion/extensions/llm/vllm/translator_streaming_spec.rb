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
      expect(chunk.tool_call.id).to eq('call_1')
      expect(chunk.tool_call.name).to eq('weather')
    end

    it 'keeps continuation fragments with nil id and raw partial arguments' do
      data = { 'id' => 'c1', 'choices' => [{ 'delta' => { 'tool_calls' => [
        { 'index' => 0, 'function' => { 'arguments' => '{"city":"Min' } }
      ] }, 'finish_reason' => nil }] }

      chunk = translator.parse_chunk(data)
      expect(chunk.type).to eq(:tool_call_delta)
      expect(chunk.tool_call.id).to be_nil
      expect(chunk.tool_call.arguments).to eq('{"city":"Min')
    end
  end
end
