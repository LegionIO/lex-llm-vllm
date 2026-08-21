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
            # V3: a FAILED /v1/models fetch is not a catalog fact. The
            # reconcile paths (replace on an active instance, re-activation
            # of an :initializing one) must keep the last good snapshot when
            # a fetch fails — publishing a replacement built from a failed
            # observation evaporates a live instance's lanes for up to one
            # discovery cycle. A successful fetch that returns an empty
            # catalog IS a fact (the provider said so) and publishes as such.
            class CatalogFetchFailure < StandardError; end

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
                raise e if e.is_a?(CatalogFetchFailure)

                # Network/runtime/parse errors mean the fetch FAILED — not
                # that the catalog is empty (V3). The failure is a typed,
                # visible fact the reconcile paths act on (skip); the
                # silent empty-set return is deleted.
                handle_exception(e, level: :warn, handled: false,
                                    operation: 'vllm.runner.discovery.discover_offerings')
                raise CatalogFetchFailure, "vLLM catalog fetch failed (#{e.class.name})", cause: e
              end

              def fetch_models(instance_cfg:)
                base_url = normalize_api_base(instance_cfg[:vllm_api_base] || instance_cfg[:endpoint])
                conn = build_catalog_connection(base_url: base_url, instance_cfg: instance_cfg)
                response = conn.get('/v1/models')
                raise CatalogFetchFailure, "vLLM /v1/models returned HTTP #{response.status}" \
                  unless response.status.between?(200, 299)

                Legion::JSON.load(response.body).fetch(:data, [])
              end

              # ── Health check (non-inference readiness) ─────────────────────

              def check_health(instance_cfg:)
                base_url = normalize_api_base(instance_cfg[:vllm_api_base] || instance_cfg[:endpoint])
                conn = build_health_connection(base_url: base_url, instance_cfg: instance_cfg)
                response = conn.get('/health')
                Legion::Extensions::Llm::Inventory::ReadinessResult.new(
                  ready: response.status == 200,
                  reason: "vLLM /health returned #{response.status}",
                  metadata: { status: response.status }
                )
              rescue Faraday::ConnectionFailed => e
                handle_exception(e, level: :warn, handled: true, operation: 'vllm.runner.discovery.health',
                                    base_url: base_url)
                readiness_failure(error: e)
              rescue StandardError => e
                raise e if discovery_programming_error?(e)

                handle_exception(e, level: :warn, handled: true, operation: 'vllm.runner.discovery.health',
                                    base_url: base_url)
                readiness_failure(error: e)
              end

              # D16: a programming bug in the discovery path must fail loud —
              # swallowing it publishes ZERO offerings (or a false "instance
              # down") and makes an activated instance invisible to the
              # coordinator. NoMethodError is a NameError subclass.
              def discovery_programming_error?(error)
                error.is_a?(NameError) || error.is_a?(ArgumentError)
              end

              # V8: the ReadinessResult contract carries no exception and no
              # endpoint. The reason is a bounded fact (class name) — never
              # an exception message (Faraday messages embed endpoint URLs),
              # and the endpoint itself never enters registry-published
              # metadata (status class only).
              def readiness_failure(error:)
                Legion::Extensions::Llm::Inventory::ReadinessResult.new(
                  ready: false,
                  reason: "vLLM /health failed (#{error.class.name})",
                  metadata: { error_class: error.class.name }
                )
              end

              # ── Instance physical identity (secondary) ─────────────────────

              # The derived host:port(/ak:<digest>) string is the SECONDARY
              # physical identity — dedup/diagnostics only. The instance
              # identity is the operator's config name (InstanceKey.instance_id);
              # two config names sharing an endpoint stay distinct instances.
              def derive_physical_id(instance_cfg:)
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
