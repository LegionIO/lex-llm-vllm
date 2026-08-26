# frozen_string_literal: true

require 'spec_helper'
require 'legion/extensions/llm/vllm/provider'

RSpec.describe Legion::Extensions::Llm::Vllm::Provider do
  # 0.8.0 (08 F3, fleet dispatch, conformance kit B1/B2): chat/stream_chat
  # take the canonical messages array POSITIONALLY — the fleet worker and the
  # kit both call `chat(messages, model:, ...)`. Every other operation stays
  # kwargs-only (no positional messages/text/prompt).
  it 'exposes the 0.8.0 completion contract: positional messages on chat/stream_chat only' do
    %i[chat stream_chat].each do |method_name|
      params = described_class.instance_method(method_name).parameters
      expect(params.first).to eq(%i[req messages]),
                              "#{method_name} must take positional messages (0.8.0 callable contract)"
      expect(params).to include(%i[keyreq model])
    end

    %i[embed image list_models discover_offerings health count_tokens].each do |method_name|
      next unless described_class.method_defined?(method_name)

      params = described_class.instance_method(method_name).parameters
      expect(params).not_to include(%i[req messages]), "#{method_name} still has positional messages"
      expect(params).not_to include(%i[req text]), "#{method_name} still has positional text"
      expect(params).not_to include(%i[req prompt]), "#{method_name} still has positional prompt"
    end
  end
end
