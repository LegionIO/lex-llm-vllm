# frozen_string_literal: true

require 'concurrent'
require 'digest'

require 'legion/logging'
require 'legion/extensions/llm/vllm'
require 'legion/extensions/llm/inventory/records'

require 'legion/extensions/llm/vllm/runners/discovery_refresh/offering_comparison'
require 'legion/extensions/llm/vllm/runners/discovery_refresh/weight_publication'
require 'legion/extensions/llm/vllm/runners/discovery_refresh/instance_lifecycle'
require 'legion/extensions/llm/vllm/runners/discovery_refresh/claim_activation'
require 'legion/extensions/llm/vllm/runners/discovery_refresh/probing'
require 'legion/extensions/llm/vllm/runners/discovery_refresh/health_display'
require 'legion/extensions/llm/vllm/runners/discovery_refresh/http'

module Legion
  module Extensions
    module Llm
      module Vllm
        module Runners
          # SSOT v3 discovery runner for vLLM. Reads the instance catalog from
          # Vllm.discover_instances, discovers models via /v1/models, probes
          # health via /health, and publishes OfferingDraft snapshots through
          # Inventory::Publisher.
          #
          # `include Legion::Extensions::Helpers::Lex` injects the module-level
          # `settings`/`log`/`handle_exception`/`cache_*` helpers — without this
          # the Every actor's `klass.send('refresh')` tick cannot resolve
          # `settings` and every claim/activate/probe silently no-ops.
          #
          # Per-instance runtime state (publisher token, probe coordinator,
          # callable, sequence, offerings) lives in a process-local
          # Concurrent::Map keyed by instance_id — NEVER in Legion::Settings,
          # which must stay a serializable config tree (a token there leaks a
          # secret and breaks on reload). Only the display-only health and
          # capabilities hashes are written back to settings, after each
          # registry commit (see the HealthDisplay helper).
          #
          # The behavior is split across mixed-in helper modules (matching the
          # provider.rb helper-module pattern) to keep each file small:
          #   InstanceLifecycle — tick entrypoint, catalog reconcile, removal
          #   ClaimActivation   — publisher, claim, readiness commit
          #   Probing           — tick refresh, cadence/reactive probes
          #   HealthDisplay     — D14 settings health/capabilities writes
          #   Http              — model/health HTTP, instance identity
          module DiscoveryRefresh
            include Legion::Extensions::Helpers::Lex
            include OfferingComparison
            include WeightPublication
            include InstanceLifecycle
            include ClaimActivation
            include Probing
            include HealthDisplay
            include Http

            # ── Process-local instance state (D5) ────────────────────────────

            @instance_states = Concurrent::Map.new

            def self.instance_states
              @instance_states
            end

            def self.reset_instance_states!
              state_mutex.synchronize do
                @instance_states.clear
                dormant_weight_tracker.clear!
              end
            end
          end
        end
      end
    end
  end
end
