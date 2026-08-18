# frozen_string_literal: true

require 'bundler/setup'
require 'logger'

require 'legion/extensions/llm'

require 'legion/extensions/llm/vllm'

require 'legion/settings'
require 'legion/logging'

# Functional stand-in for the LegionIO `Legion::Extensions::Helpers::Lex`
# helper, for vLLM specs. Provides the REAL settings/log/handle_exception the
# provider runner and actor rely on, without loading the full LegionIO helper
# stack. `settings` comes straight from Legion::Settings::Helper (legion-settings
# 1.4.2), which derives the nested extension path from the caller's namespace —
# Runners::*/Actor::* stop at NAMESPACE_BOUNDARIES, so every vLLM runner and
# actor resolves to Legion::Settings[:extensions][:llm][:vllm] — and is
# writable, so specs drive discovery + D14 health writes through the genuine
# settings tree (the loader defaults provide a live Concurrent::Hash at
# [:extensions]).
#
# The self-extend hook mirrors the real Lex so module-level runners get
# settings/log/handle_exception on the module.
module Legion
  module Extensions
    module Helpers
      module Lex
        include Legion::Logging::Helper
        include Legion::Settings::Helper

        def self.included(base)
          base.extend(base) if base.instance_of?(Module) && !base.instance_of?(Class)
        end
      end
    end
  end
end

# Load conformance kit from lex-llm gem's spec/ directory
# (spec/ ships in the gem but is NOT on the load path)
if Gem.loaded_specs['lex-llm']
  kit_path = File.join(Gem.loaded_specs['lex-llm'].full_gem_path, 'spec/legion/extensions/llm/conformance')
  Dir[File.join(kit_path, '**', '*.rb')].each { |f| require f }
end

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
