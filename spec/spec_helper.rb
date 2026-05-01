# frozen_string_literal: true

require 'bundler/setup'

# register_provider_options is not yet on Configuration — register vllm
# config options directly so the provider can initialize in specs.
require 'legion/extensions/llm'
%i[vllm_api_base vllm_api_key].each do |opt|
  Legion::Extensions::Llm::Configuration.send(:option, opt, nil)
end

require 'legion/extensions/llm/vllm'
