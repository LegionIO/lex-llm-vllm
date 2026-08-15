# frozen_string_literal: true

module Legion
  module Extensions
    module Llm
      module Vllm
        module Runners
          module DiscoveryRefresh
            # Tick entrypoint, catalog reconcile, and removal for the vLLM
            # discovery runner. Mixed into DiscoveryRefresh.
            module InstanceLifecycle
              # ── Entrypoint (called by the Every actor each tick) ───────────

              def refresh(**)
                reconcile_instances
                { success: true }
              rescue StandardError => e
                handle_exception(e, level: :warn, operation: 'vllm.runner.discovery.refresh')
                { success: false }
              end

              # Re-scan the configured catalog each tick (D4 reconcile): claim
              # instances that appeared since boot, remove ones that vanished,
              # and refresh/probe every known instance. Vllm.discover_instances
              # already applies the D3 filtering (no synthetic :default, no
              # endpoint-less entries).
              def reconcile_instances
                configured = Vllm.discover_instances
                by_id = configured.each_with_object({}) do |(name, instance_cfg), ids|
                  ids[derive_instance_id(instance_cfg: instance_cfg)] = [name, instance_cfg]
                end

                instance_states.each_key do |instance_id|
                  next if by_id.key?(instance_id)

                  remove_instance_state(instance_id)
                end

                by_id.each do |instance_id, (name, instance_cfg)|
                  update_instance(name: name, instance_id: instance_id, instance_cfg: instance_cfg)
                rescue StandardError => e
                  handle_exception(e, level: :warn, operation: 'vllm.runner.discovery.instance',
                                      instance_name: name.to_s)
                end
              end

              def remove_all_instances(**)
                instance_states.each_key { |instance_id| remove_instance_state(instance_id) }
                { success: true }
              end

              def update_instance(name:, instance_id:, instance_cfg:)
                if instance_states.key?(instance_id)
                  refresh_instance(instance_id: instance_id, instance_cfg: instance_cfg)
                else
                  claim_and_activate_instance(name: name, instance_id: instance_id, instance_cfg: instance_cfg)
                end
              end

              def remove_instance_state(instance_id)
                state = instance_states.delete(instance_id)
                return unless state

                publisher.remove_instance(instance_id: instance_id, publisher_token: state[:publisher_token])
                clear_settings_health(name: state[:name])
              rescue StandardError => e
                handle_exception(e, level: :warn, operation: 'vllm.runner.discovery.remove_instance',
                                    instance_id: instance_id)
              end
            end
          end
        end
      end
    end
  end
end
