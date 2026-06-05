# frozen_string_literal: true

require 'bundler/setup'
require 'logger'

# register_provider_options is not yet on Configuration — register vllm
# config options directly so the provider can initialize in specs.
require 'legion/extensions/llm'
%i[vllm_api_base vllm_api_key].each do |opt|
  Legion::Extensions::Llm::Configuration.send(:option, opt, nil)
end

require 'legion/extensions/llm'
require 'legion/extensions/llm/vllm'

if defined?(Legion::Logging)
  null_logger = Logger.new(File::NULL)
  null_logger.level = Logger::DEBUG
  Legion::Logging.instance_variable_set(:@log, null_logger)
  Legion::Logging.instance_variable_set(
    :@current_settings,
    {
      level: :debug,
      format: :text,
      async: false,
      trace: false,
      trace_size: 0,
      extended: false,
      log_file: nil,
      log_stdout: false,
      include_pid: false,
      color: false
    }.freeze
  )
  Legion::Logging.instance_variable_set(:@configuration_generation, Legion::Logging.configuration_generation + 1)
end
