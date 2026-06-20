# frozen_string_literal: true

require 'digest'

begin
  require 'legion/extensions/actors/every'
rescue LoadError => e
  warn(e.message) if $VERBOSE
end

begin
  require 'legion/extensions/llm/inventory/scoped_refresher'
rescue LoadError => e
  warn(e.message) if $VERBOSE
end

return unless defined?(Legion::Extensions::Actors::Every)

module Legion
  module Extensions
    module Llm
      module Vllm
        module Actor
          # Periodic actor that refreshes the vLLM discovered model list.
          class DiscoveryRefresh < Legion::Extensions::Actors::Every
            include Legion::Logging::Helper

            if defined?(Legion::Extensions::Llm::Inventory::ScopedRefresher)
              include Legion::Extensions::Llm::Inventory::ScopedRefresher
            end

            REFRESH_INTERVAL = 1800

            def self.every_seconds = 60

            def runner_class    = self.class
            def runner_function = 'manual'
            def run_now?        = true
            def use_runner?     = false
            def check_subtask?  = false
            def generate_task?  = false

            def time
              return REFRESH_INTERVAL unless defined?(Legion::Settings)

              Legion::Settings.dig(:extensions, :llm, :vllm, :discovery_interval) || REFRESH_INTERVAL
            end

            def scope_key                = { provider: :vllm }
            def offering_type(raw_type)  = %i[embed embedding].include?(raw_type) ? :embedding : :inference

            def vllm_cfg
              return unless defined?(Legion::Settings)

              Legion::Settings.dig(:extensions, :llm,
                                   :vllm)
            end

            def compute_lanes_for_scope(**)
              return [] unless defined?(Legion::LLM::Call::Registry)

              vllm_instances.flat_map { |entry| lanes_from_instance(entry) }
            rescue StandardError => e
              handle_exception(e, level: :warn, handled: true, operation: 'vllm.actor.compute_lanes_for_scope')
              []
            end

            def credential_hash(**)
              cfg = vllm_cfg
              Digest::SHA256.hexdigest(cfg&.dig(:api_key).to_s + cfg&.dig(:instances).to_s)[0, 16]
            rescue StandardError
              'unknown'
            end

            def manual
              run_scoped_tick
            rescue StandardError => e
              handle_exception(e, level: :warn, handled: true, operation: 'vllm.actor.discovery_refresh')
            end

            private

            def run_scoped_tick
              return unless defined?(Legion::Extensions::Llm::Inventory::ScopedRefresher)
              return unless self.class.ancestors.include?(Legion::Extensions::Llm::Inventory::ScopedRefresher)

              tick
            end

            def vllm_instances
              Legion::LLM::Call::Registry.all_instances.select { |e| (e[:provider] || '').to_sym == :vllm }
            end

            def lanes_from_instance(instance_entry)
              adapter = instance_entry[:adapter]
              return [] unless adapter.respond_to?(:discover_offerings)

              Array(adapter.discover_offerings(live: true)).flat_map do |offering|
                raw  = offering_to_hash(offering)
                lane = build_lane(raw, instance_entry)
                fleet = maybe_fleet_lane(lane)
                fleet ? [lane, fleet] : [lane]
              end
            end

            # ModelOffering objects do not implement `[]`; normalize to a Hash so the
            # rest of the writer stays Hash-shaped. Hash inputs pass through untouched.
            def offering_to_hash(offering)
              return offering if offering.is_a?(Hash)

              hash = offering.to_h
              hash[:type] ||= hash[:usage_type]
              hash[:enabled] = offering.respond_to?(:enabled?) ? offering.enabled? : true
              hash
            end

            def build_lane(offering, instance_entry) # rubocop:disable Metrics/AbcSize,Metrics/CyclomaticComplexity
              tier            = offering[:tier] || :direct
              type            = offering_type(offering[:type])
              instance_id     = offering[:instance_id] ||
                                instance_entry[:instance] ||
                                instance_entry[:instance_id] ||
                                instance_entry[:id]
              provider_family = offering[:provider_family] || :vllm
              model           = offering[:model]
              lane_id = Legion::Extensions::Llm::Inventory::ScopedRefresher.compose_id(
                tier: tier, provider_family: provider_family, instance_id: instance_id, type: type, model: model
              )
              { id: lane_id, tier: tier, provider_family: provider_family, instance_id: instance_id,
                model: model, canonical_model_alias: offering[:canonical_model_alias], type: type,
                capabilities: normalize_caps(offering[:capabilities]),
                limits: offering[:limits] || {}, enabled: offering.fetch(:enabled, true), cost: offering[:cost] || {} }
            end

            def maybe_fleet_lane(lane)
              return unless lane[:type] == :inference && vllm_cfg&.dig(:fleet, :dispatch, :enabled)

              fleet_id = Legion::Extensions::Llm::Inventory::ScopedRefresher.compose_id(
                tier: :fleet, provider_family: lane[:provider_family],
                instance_id: lane[:instance_id], type: lane[:type], model: lane[:model]
              )
              lane.merge(id: fleet_id, tier: :fleet)
            end

            def normalize_caps(caps)
              return [] unless defined?(Legion::Extensions::Llm::Inventory::Capabilities)

              Legion::Extensions::Llm::Inventory::Capabilities.normalize(caps)
            end
          end
        end
      end
    end
  end
end
