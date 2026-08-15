# frozen_string_literal: true

require 'uri'
require 'faraday'

require 'legion/extensions/llm/vllm/helpers/offering_builder'

module Legion
  module Extensions
    module Llm
      module Vllm
        module Runners
          module DiscoveryRefresh
            # Offering discovery, health probing, and instance-identity helpers
            # for the vLLM discovery runner. Mixed into DiscoveryRefresh.
            module Http
              # ── Offering discovery ─────────────────────────────────────────

              def fetch_offerings(instance_cfg:, instance_key:)
                models = fetch_models(instance_cfg: instance_cfg)
                builder = Legion::Extensions::Llm::Vllm::Helpers::OfferingBuilder.new(
                  instance_cfg: instance_cfg, instance_key: instance_key
                )
                models.filter_map do |model_data|
                  model_id = model_data[:id].to_s
                  next if model_id.empty?

                  builder.build(model_id: model_id, model_data: model_data)
                end
              rescue StandardError => e
                raise e if discovery_programming_error?(e)

                # Network/runtime/parse errors (Faraday, timeout, JSON,
                # malformed model data) mean the instance has no catalog right
                # now — an empty set is the correct availability fact.
                handle_exception(e, level: :warn, operation: 'vllm.runner.discovery.discover_offerings')
                []
              end

              def fetch_models(instance_cfg:)
                base_url = normalize_api_base(instance_cfg[:vllm_api_base] || instance_cfg[:endpoint])
                conn = build_catalog_connection(base_url: base_url, instance_cfg: instance_cfg)
                Legion::JSON.load(conn.get('/v1/models').body).fetch(:data, [])
              end

              # ── Health check (non-inference readiness) ─────────────────────

              def check_health(instance_cfg:)
                base_url = normalize_api_base(instance_cfg[:vllm_api_base] || instance_cfg[:endpoint])
                conn = build_health_connection(base_url: base_url, instance_cfg: instance_cfg)
                response = conn.get('/health')
                Legion::Extensions::Llm::Inventory::ReadinessResult.new(
                  ready: response.status == 200,
                  reason: "vLLM /health returned #{response.status}",
                  metadata: { status: response.status, base_url: base_url }
                )
              rescue Faraday::ConnectionFailed => e
                handle_exception(e, level: :warn, handled: true, operation: 'vllm.runner.discovery.health',
                                    base_url: base_url)
                readiness_failure(reason: "vLLM /health connection failed: #{e.message}", error: e)
              rescue StandardError => e
                raise e if discovery_programming_error?(e)

                handle_exception(e, level: :warn, handled: true, operation: 'vllm.runner.discovery.health',
                                    base_url: base_url)
                readiness_failure(reason: "vLLM /health error: #{e.message}", error: e)
              end

              # D16: a programming bug in the discovery path must fail loud —
              # swallowing it publishes ZERO offerings (or a false "instance
              # down") and makes an activated instance invisible to the
              # coordinator. NoMethodError is a NameError subclass.
              def discovery_programming_error?(error)
                error.is_a?(NameError) || error.is_a?(ArgumentError)
              end

              def readiness_failure(reason:, error:)
                Legion::Extensions::Llm::Inventory::ReadinessResult.new(
                  ready: false, reason: reason,
                  metadata: { error_class: error.class.name }
                )
              end

              # ── Instance identity ──────────────────────────────────────────

              def derive_instance_id(instance_cfg:)
                base_url = instance_cfg[:vllm_api_base] || instance_cfg[:endpoint]
                host_port = extract_host_port(url: normalize_api_base(base_url))
                api_key = instance_cfg[:vllm_api_key]
                if api_key.is_a?(String) && !api_key.strip.empty?
                  return "#{host_port}/ak:#{::Digest::SHA256.hexdigest(api_key)[0, 6]}"
                end

                host_port
              end

              def extract_host_port(url:)
                uri = URI.parse(url.to_s)
                "#{uri.host || 'localhost'}:#{uri.port}"
              rescue URI::InvalidURIError => e
                handle_exception(e, level: :warn, handled: true,
                                    operation: 'vllm.runner.discovery.extract_host_port', url: url.to_s)
                raise
              end

              # Strip a trailing /v1 from an API base. Deliberately has NO
              # localhost fallback — an instance with no resolvable endpoint is
              # skipped by discovery rather than silently claimed at localhost.
              def normalize_api_base(url)
                url.to_s.sub(%r{/v1/?\z}, '')
              end

              private

              def build_catalog_connection(base_url:, instance_cfg:)
                Faraday.new(url: base_url) do |f|
                  f.options.timeout = 15
                  f.options.open_timeout = 5
                  f.headers['Accept'] = 'application/json'
                  apply_auth_header(faraday: f, instance_cfg: instance_cfg)
                  f.adapter Faraday.default_adapter
                end
              end

              def build_health_connection(base_url:, instance_cfg:)
                Faraday.new(url: base_url) do |f|
                  f.options.timeout = 5
                  f.options.open_timeout = 3
                  apply_auth_header(faraday: f, instance_cfg: instance_cfg)
                  f.adapter Faraday.default_adapter
                end
              end

              def apply_auth_header(faraday:, instance_cfg:)
                api_key = instance_cfg[:vllm_api_key]
                return unless api_key.is_a?(String) && !api_key.strip.empty?

                faraday.headers['Authorization'] = "Bearer #{api_key}"
              end
            end
          end
        end
      end
    end
  end
end
