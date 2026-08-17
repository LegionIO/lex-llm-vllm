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
              #
              # Instance identity is the operator's CONFIG NAME (the key the
              # router uses for instances.<name> settings lookups). The derived
              # host:port/ak physical id is a secondary field only — two config
              # names pointing at the same endpoint remain distinct instances.
              def reconcile_instances
                configured = Vllm.discover_instances

                instance_states.each_key do |instance_id|
                  next if configured.key?(instance_id)

                  remove_instance_state(instance_id)
                end

                configured.each do |name, instance_cfg|
                  update_instance(name: name, instance_cfg: instance_cfg)
                rescue StandardError => e
                  handle_exception(e, level: :warn, operation: 'vllm.runner.discovery.instance',
                                      instance_name: name.to_s)
                end
              end

              def remove_all_instances(**)
                instance_states.each_key { |instance_id| remove_instance_state(instance_id) }
                { success: true }
              end

              def update_instance(name:, instance_cfg:)
                state = instance_states[name]
                if state && physical_id_changed?(state, instance_cfg)
                  # The physical target moved (endpoint or API key changed) —
                  # the captured callable points at the old endpoint, so drop
                  # and re-claim under the same config-name identity.
                  remove_instance_state(name)
                  claim_and_activate_instance(name: name, instance_cfg: instance_cfg)
                elsif state
                  refresh_instance(instance_id: name, instance_cfg: instance_cfg)
                else
                  claim_and_activate_instance(name: name, instance_cfg: instance_cfg)
                end
              end

              def physical_id_changed?(state, instance_cfg)
                state[:instance_key].physical_id != derive_physical_id(instance_cfg: instance_cfg)
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
