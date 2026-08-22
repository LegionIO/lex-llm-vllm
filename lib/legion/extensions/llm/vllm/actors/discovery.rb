# frozen_string_literal: true

require 'legion/extensions/llm/discovery/actor'

# The base discovery actor only exists inside the daemon (it inherits the
# LegionIO time-based Every actor). In a standalone load, define nothing.
return unless defined?(Legion::Extensions::Llm::Discovery::Actor)

module Legion
  module Extensions
    module Llm
      module Vllm
        module Actor
          # vLLM discovery actor: an EMPTY subclass of the shared base. The timer,
          # the dispatch, and the runner-resolution convention are inherited —
          # this class redefines nothing. The vLLM-specific work lives in
          # Vllm::Runners::Discovery, resolved by the base from this namespace.
          class Discovery < Legion::Extensions::Llm::Discovery::Actor; end
        end
      end
    end
  end
end
