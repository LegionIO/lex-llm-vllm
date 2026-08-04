# frozen_string_literal: true

require 'spec_helper'
require 'legion/extensions/llm/vllm/provider'

# N×N deterministic encode of the 2026-08-03 dead-stop root cause.
#
# Live capture (codex_matt_dead_stop_logs.log) showed vLLM streaming two
# parallel tool calls; when argument fragments for index 0 and index 1
# INTERLEAVE, the StreamAccumulator appends nil-id fragments to
# @latest_tool_call_id (recency) instead of correlating by the wire
# `index` field. Result: one call gets cross-contaminated arguments, the
# other truncated/empty arguments -> dispatch_failed / garbage tool result
# -> degenerate turn -> clean end_turn dead stop.
#
# This cell replays the captured chunk shape verbatim with alternating
# indices. It MUST fail on current code and pass only when fragments are
# correlated by wire index. e2e can never express this deterministically
# (interleaving is chunk-timing dependent); this layer can.
RSpec.describe Legion::Extensions::Llm::Vllm::Provider do
  let(:provider) { described_class.allocate }

  def tool_delta(index:, arguments:, id: nil, name: nil)
    call = { 'index' => index, 'function' => { 'arguments' => arguments } }
    call['id'] = id if id
    call['function']['name'] = name if name
    { 'id' => 'chatcmpl-deadstop', 'model' => 'gemma-4-31b-it',
      'choices' => [{ 'index' => 0, 'delta' => { 'tool_calls' => [call] },
                      'finish_reason' => nil }] }
  end

  describe 'parallel tool calls with interleaved argument fragments' do
    subject(:message) do
      accumulator = Legion::Extensions::Llm::StreamAccumulator.new
      sequence.each do |data|
        chunk = provider.send(:build_chunk, data)
        accumulator.add(chunk) if chunk
      end
      accumulator.to_message(nil)
    end

    let(:sequence) do
      [
        # openers carry id + name + index
        tool_delta(index: 0, id: 'call_A', name: 'bash', arguments: '{"command": "echo AL'),
        tool_delta(index: 1, id: 'call_B', name: 'bash', arguments: '{"command": "echo BR'),
        # continuation fragments carry ONLY index (id/name nil) — interleaved
        tool_delta(index: 0, arguments: 'PHA_7Q"}'),
        tool_delta(index: 1, arguments: 'AVO_4Z"}'),
        { 'id' => 'chatcmpl-deadstop', 'model' => 'gemma-4-31b-it',
          'choices' => [{ 'index' => 0, 'delta' => {}, 'finish_reason' => 'tool_calls' }] }
      ]
    end

    it 'reassembles each call from its own wire index, not recency' do
      expect(message.tool_calls.keys).to match_array(%w[call_A call_B])
      expect(message.tool_calls['call_A'].arguments).to eq({ 'command' => 'echo ALPHA_7Q' })
      expect(message.tool_calls['call_B'].arguments).to eq({ 'command' => 'echo BRAVO_4Z' })
      expect(message.stop_reason).to eq(:tool_use)
    end
  end
end
