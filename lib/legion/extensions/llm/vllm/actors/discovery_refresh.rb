# frozen_string_literal: true

require 'digest'
require 'uri'

begin
  require 'legion/extensions/actors/every'
rescue LoadError => e
  warn(e.message) if $VERBOSE
end

require 'legion/extensions/llm/inventory/publisher'
require 'legion/extensions/llm/inventory/identity'
require 'legion/extensions/llm/inventory/records'
require 'legion/extensions/llm/inventory/evidence'
require 'legion/extensions/llm/inventory/probe_coordinator'
require 'legion/extensions/llm/routing/provider_outcome'
require 'legion/extensions/llm/taxonomies'
require 'legion/extensions/llm/capabilities'

return unless defined?(Legion::Extensions::Actors::Every)

module Legion
  module Extensions
    module Llm
      module Vllm
        module Actor
          # ── Evidence building helpers ─────────────────────────────────────

          # Methods for constructing OperationEvidence, CapabilityEvidence, and
          # ValueEvidence objects from raw vLLM model-catalog data.
          module DiscoveryRefreshEvidenceBuilders
            private

            def build_operation_evidence(embed_supported:)
              now = Time.now.freeze
              embed_status = case embed_supported
                             when true  then :supported
                             when false then :unsupported
                             else            :unknown
                             end
              {
                chat: op_evidence(operation: :chat, status: :supported, observed_at: now),
                stream_chat: op_evidence(operation: :stream_chat, status: :supported, observed_at: now),
                embed: op_evidence(operation: :embed,         status: embed_status, observed_at: now),
                image: op_evidence(operation: :image,         status: :unsupported, observed_at: now),
                transcribe: op_evidence(operation: :transcribe, status: :unsupported, observed_at: now),
                translate: op_evidence(operation: :translate, status: :unsupported, observed_at: now),
                speak: op_evidence(operation: :speak, status: :unsupported, observed_at: now),
                moderate: op_evidence(operation: :moderate, status: :unsupported, observed_at: now),
                count_tokens: op_evidence(operation: :count_tokens, status: :unknown, observed_at: now)
              }
            end

            def op_evidence(operation:, status:, observed_at:)
              source = status == :unknown ? :default_false : :provider_implementation
              Legion::Extensions::Llm::Inventory::OperationEvidence.new(
                operation: operation, status: status, source: source, observed_at: observed_at
              )
            end

            def build_capability_evidence(instance_cfg:, model_id:, embed_supported:)
              build_core_capabilities.merge(
                build_optional_capabilities(instance_cfg: instance_cfg,
                                            model_id: model_id,
                                            embed_supported: embed_supported)
              )
            end

            def build_core_capabilities
              {
                completion: cap_evidence(capability: :completion, status: :supported,
                                         source: :provider_implementation),
                streaming: cap_evidence(capability: :streaming, status: :supported,
                                        source: :provider_implementation)
              }
            end

            def build_optional_capabilities(instance_cfg:, model_id:, embed_supported:)
              result = build_inference_capabilities(instance_cfg: instance_cfg, model_id: model_id)
              result[:vision] = cap_evidence(
                capability: :vision,
                status: resolve_vision_status(instance_cfg: instance_cfg),
                source: resolve_vision_source(instance_cfg: instance_cfg)
              )
              if embed_supported
                result[:embedding] = cap_evidence(
                  capability: :embedding, status: :supported, source: :provider_implementation
                )
              end
              result
            end

            def build_inference_capabilities(instance_cfg:, model_id:)
              thinking_cfg = resolve_thinking_config(instance_cfg: instance_cfg, model_id: model_id)
              tools_cfg    = resolve_tools_config(instance_cfg: instance_cfg, model_id: model_id)
              {
                thinking: cap_evidence(capability: :thinking, status: thinking_cfg[:status],
                                       source: thinking_cfg[:source]),
                tools: cap_evidence(capability: :tools, status: tools_cfg[:status],
                                    source: tools_cfg[:source])
              }
            end

            def cap_evidence(capability:, status:, source:)
              Legion::Extensions::Llm::Inventory::CapabilityEvidence.new(
                capability: capability, status: status, source: source, observed_at: Time.now.freeze
              )
            end

            def resolve_thinking_config(instance_cfg:, model_id:)
              model_cfg = instance_cfg.dig(:models, model_id.to_sym)
              if model_cfg.is_a?(Hash) && model_cfg.key?(:enable_thinking)
                return { status: :unknown,
                         source: :model_override }
              end
              return { status: :unknown, source: :instance_override } if instance_cfg.key?(:enable_thinking)

              { status: :unknown, source: :default_false }
            end

            def resolve_tools_config(instance_cfg:, model_id:)
              model_cfg = instance_cfg.dig(:models, model_id.to_sym)
              if model_cfg.is_a?(Hash) && model_cfg.key?(:enable_tools)
                return { status: :unknown,
                         source: :model_override }
              end
              return { status: :unknown, source: :instance_override } if instance_cfg.key?(:enable_tools)

              { status: :unknown, source: :default_false }
            end

            def resolve_vision_status(**)
              :unknown
            end

            def resolve_vision_source(instance_cfg:)
              return :instance_override if instance_cfg.key?(:enable_vision)

              :default_false
            end
          end

          # ── Value evidence helpers ────────────────────────────────────────

          # Methods for building ValueEvidence objects for context window, max output,
          # embedding dimensions, model revision, and tokenizer catalog data.
          module DiscoveryRefreshValueEvidenceHelpers
            private

            def build_context_evidence(model_data:)
              ctx = model_data[:max_model_len]
              if ctx.is_a?(Integer) && ctx.positive?
                Legion::Extensions::Llm::Inventory::ValueEvidence.new(
                  status: :known, value: ctx, source: :provider_catalog
                )
              else
                absent_value_evidence
              end
            end

            def build_max_output_evidence(model_data:)
              max_out = model_data[:max_output_tokens] || model_data[:max_completion_tokens]
              if max_out.is_a?(Integer) && max_out.positive?
                Legion::Extensions::Llm::Inventory::ValueEvidence.new(
                  status: :known, value: max_out, source: :provider_catalog
                )
              else
                absent_value_evidence
              end
            end

            def build_embedding_dimensions_evidence(model_data:, embed_supported:)
              return absent_value_evidence unless embed_supported

              dims = model_data[:embedding_dimensions]
              if dims.is_a?(Array) && !dims.empty? && dims.all? { |d| d.is_a?(Integer) && d.positive? }
                Legion::Extensions::Llm::Inventory::ValueEvidence.new(
                  status: :known, value: dims.uniq.sort, source: :provider_catalog
                )
              else
                absent_value_evidence
              end
            end

            def build_model_revision_evidence(model_data:)
              revision = model_data[:revision] || model_data[:model_revision]
              if revision.is_a?(String) && !revision.strip.empty?
                Legion::Extensions::Llm::Inventory::ValueEvidence.new(
                  status: :known, value: revision.strip, source: :provider_catalog
                )
              else
                absent_value_evidence
              end
            end

            def build_tokenizer_evidence(model_data:)
              tokenizer = model_data[:tokenizer]
              return absent_value_evidence unless tokenizer_present?(tokenizer: tokenizer)

              Legion::Extensions::Llm::Inventory::ValueEvidence.new(
                status: :known,
                value: extract_tokenizer_value(tokenizer: tokenizer),
                source: :provider_catalog
              )
            end

            def tokenizer_present?(tokenizer:)
              tokenizer.is_a?(Hash) && tokenizer[:estimator].is_a?(String) && !tokenizer[:estimator].strip.empty?
            end

            def extract_tokenizer_value(tokenizer:)
              {
                estimator: tokenizer[:estimator].strip,
                version: (tokenizer[:version] || '1.0').to_s.strip,
                parameters: tokenizer[:parameters].is_a?(Hash) ? tokenizer[:parameters] : {}
              }
            end

            def absent_value_evidence
              Legion::Extensions::Llm::Inventory::ValueEvidence.new(status: :unknown, source: :absent)
            end
          end

          # ── Configuration and HTTP helpers ────────────────────────────────

          # Methods for reading instance configuration, deriving stable instance IDs,
          # and building Faraday HTTP connections.
          module DiscoveryRefreshConfigHelpers
            private

            def configured_instances
              instances = {}
              cfg_instances = settings[:instances]
              if cfg_instances.is_a?(Hash)
                cfg_instances.each do |name, config|
                  instances[name.to_sym] = normalize_instance_config(config: config)
                end
              end
              instances[:local] = auto_discover_local if instances.empty?
              instances
            end

            def auto_discover_local
              {
                vllm_api_base: settings[:endpoint],
                tier: :local,
                vllm_api_key: settings[:credentials][:api_key]
              }
            end

            def normalize_instance_config(config:)
              normalized = config.to_h.transform_keys(&:to_sym)
              resolve_api_base(normalized: normalized)
              resolve_instance_credentials(normalized: normalized)
              normalized[:tier] ||= :direct
              normalized
            end

            def resolve_api_base(normalized:)
              normalized[:vllm_api_base] ||= normalized.delete(:base_url)
              normalized[:vllm_api_base] ||= normalized.delete(:api_base)
              normalized[:vllm_api_base] ||= normalized.delete(:endpoint)
              return unless normalized[:vllm_api_base]

              normalized[:vllm_api_base] = normalized[:vllm_api_base].to_s.sub(%r{/v1/?\z}, '')
            end

            def resolve_instance_credentials(normalized:)
              creds = normalized.delete(:credentials)
              return unless creds.is_a?(Hash)

              creds = creds.transform_keys(&:to_sym)
              normalized[:vllm_api_key] ||= creds[:api_key]
            end

            def derive_instance_id(instance_cfg:)
              base_url = instance_cfg[:vllm_api_base] || instance_cfg[:endpoint]
              host_port = extract_host_port(url: normalize_api_base(base_url))
              api_key = instance_cfg[:vllm_api_key]
              if api_key.is_a?(String) && !api_key.strip.empty?
                return "#{host_port}/ak:#{::Digest::SHA256.hexdigest(api_key)[0,
                                                                              6]}"
              end

              host_port
            end

            def extract_host_port(url:)
              uri = URI.parse(url.to_s)
              "#{uri.host || 'localhost'}:#{uri.port}"
            rescue URI::InvalidURIError => e
              handle_exception(e, level: :warn, handled: true, operation: 'vllm.actor.extract_host_port',
                                  url: url.to_s)
              'unknown:0'
            end

            def normalize_api_base(url)
              (url || 'http://localhost:8000').to_s.sub(%r{/v1/?\z}, '')
            end

            def build_health_connection(base_url:, instance_cfg:)
              require 'faraday'
              Faraday.new(url: base_url) do |f|
                f.options.timeout = 5
                f.options.open_timeout = 3
                apply_auth_header(faraday: f, instance_cfg: instance_cfg)
                f.adapter Faraday.default_adapter
              end
            end

            def build_api_connection(base_url:, instance_cfg:)
              require 'faraday'
              Faraday.new(url: base_url) do |f|
                f.options.timeout = 15
                f.options.open_timeout = 5
                f.headers['Accept'] = 'application/json'
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

          # ── Health check helpers ──────────────────────────────────────────

          # Non-inference readiness operations for vLLM instances.
          module DiscoveryRefreshHealthHelpers
            private

            def check_health(instance_cfg:)
              base_url = normalize_api_base(instance_cfg[:vllm_api_base] || instance_cfg[:endpoint])
              conn = build_health_connection(base_url: base_url, instance_cfg: instance_cfg)
              response = conn.get('/health')
              build_readiness_from_response(response: response, base_url: base_url)
            rescue Faraday::ConnectionFailed => e
              readiness_failure(reason: "vLLM /health connection failed: #{e.message}", error: e)
            rescue StandardError => e
              readiness_failure(reason: "vLLM /health error: #{e.message}", error: e)
            end

            def build_readiness_from_response(response:, base_url:)
              Legion::Extensions::Llm::Inventory::ReadinessResult.new(
                ready: response.status == 200,
                reason: "vLLM /health returned #{response.status}",
                metadata: { status: response.status, base_url: base_url }
              )
            end

            def readiness_failure(reason:, error:)
              Legion::Extensions::Llm::Inventory::ReadinessResult.new(
                ready: false, reason: reason,
                metadata: { error_class: error.class.name }
              )
            end
          end

          # ── Offering discovery helpers ────────────────────────────────────

          # Methods for fetching the vLLM model catalog and building OfferingDraft
          # records from raw API responses.
          module DiscoveryRefreshOfferingHelpers
            private

            def discover_offerings_for_instance(instance_cfg:, instance_key:)
              models = fetch_models(instance_cfg: instance_cfg)
              models.filter_map do |model_data|
                model_id = model_data[:id].to_s
                next if model_id.empty?

                build_offering_draft(model_id: model_id, model_data: model_data,
                                     instance_cfg: instance_cfg, instance_key: instance_key)
              end
            rescue StandardError => e
              handle_exception(e, level: :warn, operation: 'vllm.actor.discover_offerings')
              []
            end

            def fetch_models(instance_cfg:)
              base_url = normalize_api_base(instance_cfg[:vllm_api_base] || instance_cfg[:endpoint])
              conn = build_api_connection(base_url: base_url, instance_cfg: instance_cfg)
              Legion::JSON.load(conn.get('/v1/models').body).fetch(:data, [])
            end

            def build_offering_draft(model_id:, model_data:, instance_cfg:, instance_key:)
              tier          = instance_cfg[:tier] || :direct
              embed_sup     = embedding_supported?(model_data: model_data)
              Legion::Extensions::Llm::Inventory::OfferingDraft.new(
                provider_native_key: model_id, model: model_id, tier: tier,
                operation_evidence: build_operation_evidence(embed_supported: embed_sup),
                capability_evidence: build_capability_evidence(instance_cfg: instance_cfg,
                                                               model_id: model_id,
                                                               embed_supported: embed_sup),
                context_evidence: build_context_evidence(model_data: model_data),
                max_output_evidence: build_max_output_evidence(model_data: model_data),
                embedding_dimensions_evidence: build_embedding_dimensions_evidence(model_data: model_data,
                                                                                   embed_supported: embed_sup),
                model_revision_evidence: build_model_revision_evidence(model_data: model_data),
                tokenizer_evidence: build_tokenizer_evidence(model_data: model_data),
                quota_domains: {},
                metadata: build_offering_metadata(model_data: model_data, instance_key: instance_key),
                publication_source: :provider_catalog
              )
            end

            def embedding_supported?(model_data:)
              return true if model_data[:type].to_s == 'embedding'
              return true if model_data[:capabilities].is_a?(Array) && model_data[:capabilities].include?('embedding')

              false
            end

            def build_offering_metadata(model_data:, instance_key:)
              meta = { raw_model: model_data[:id].to_s }
              meta[:parameter_count] = model_data[:parameter_count] if model_data[:parameter_count]
              meta[:quantization]    = model_data[:quantization].to_s if model_data[:quantization]
              meta[:instance_id]     = instance_key.instance_id
              meta
            end
          end

          # ── Activation helpers ────────────────────────────────────────────

          # Methods for the initial claim + startup gate sequence:
          # initial_discovery, claim_and_activate_instance, and sub-steps.
          module DiscoveryRefreshActivationHelpers
            private

            def initial_discovery
              @instance_states = {}
              configured_instances.each do |name, instance_cfg|
                claim_and_activate_instance(name:, instance_cfg:)
              rescue StandardError => e
                handle_exception(e, level: :warn, operation: 'vllm.actor.claim_instance',
                                    instance_name: name.to_s)
              end
            end

            def claim_and_activate_instance(name:, instance_cfg:)
              instance_id       = derive_instance_id(instance_cfg:)
              instance_key      = build_instance_key(instance_id:)
              callable          = VllmCallable.new(instance_cfg: instance_cfg, logger: log)
              probe_coordinator = build_probe_coordinator(instance_key:, instance_id:)
              publisher_token   = publisher.claim_instance(
                instance_id: instance_id, callable: callable, probe_request_handle: probe_coordinator
              )
              offerings = discover_offerings_for_instance(instance_cfg:, instance_key:)
              perform_initial_readiness(instance_id:, publisher_token:, offerings:, instance_cfg:)
              store_instance_state(name:, instance_id:, instance_key:, instance_cfg:,
                                   callable:, probe_coordinator:, publisher_token:, offerings:)
            end

            def build_instance_key(instance_id:)
              Legion::Extensions::Llm::Inventory::Identity::InstanceKey.new(
                provider_family: :vllm, instance_id: instance_id
              )
            end

            def build_probe_coordinator(instance_key:, instance_id:)
              Legion::Extensions::Llm::Inventory::ProbeCoordinator.new(
                instance_key: instance_key, enqueue: build_probe_enqueue(instance_id:)
              )
            end

            def perform_initial_readiness(instance_id:, publisher_token:, offerings:, instance_cfg:)
              probe_token = publisher.readiness_probe_started(
                instance_id: instance_id, publisher_token: publisher_token
              )
              readiness = check_health(instance_cfg:)
              if readiness.ready?
                publisher.activate_instance_snapshot(
                  instance_id: instance_id, publisher_token: publisher_token,
                  offerings: offerings, sequence: 0, probe_token: probe_token
                )
              else
                publisher.readiness_failed(
                  instance_id: instance_id, probe_token: probe_token, reason: readiness.reason
                )
              end
            end

            def store_instance_state(name:, instance_id:, instance_key:, instance_cfg:, **opts)
              @instance_states[instance_id] = {
                name: name, instance_key: instance_key, instance_cfg: instance_cfg,
                callable: opts[:callable], probe_coordinator: opts[:probe_coordinator],
                publisher_token: opts[:publisher_token], sequence: 0, offerings: opts[:offerings]
              }
            end
          end

          # ── Refresh and probing helpers ───────────────────────────────────

          # Methods for periodic catalog refresh, cadence probes, reactive probes,
          # probe result reporting, and graceful instance removal.
          module DiscoveryRefreshRefreshHelpers
            private

            def tick_refresh
              @instance_states.each do |instance_id, state|
                refresh_instance(instance_id:, state:)
              rescue StandardError => e
                handle_exception(e, level: :warn, operation: 'vllm.actor.refresh_instance',
                                    instance_id: instance_id)
              end
            end

            def refresh_instance(instance_id:, state:)
              new_offerings = discover_offerings_for_instance(
                instance_cfg: state[:instance_cfg], instance_key: state[:instance_key]
              )
              if new_offerings != state[:offerings]
                state[:sequence] += 1
                publisher.replace_instance_snapshot(
                  instance_id: instance_id, publisher_token: state[:publisher_token],
                  offerings: new_offerings, sequence: state[:sequence]
                )
                state[:offerings] = new_offerings
              end
              run_cadence_probe(instance_id:, state:)
            end

            def run_cadence_probe(instance_id:, state:)
              coordinator = state[:probe_coordinator]
              return unless coordinator.begin_probe

              probe_token = publisher.readiness_probe_started(
                instance_id: instance_id, publisher_token: state[:publisher_token]
              )
              readiness = check_health(instance_cfg: state[:instance_cfg])
              coordinator.finish_probe
              report_probe_result(instance_id:, probe_token:, readiness:)
            rescue StandardError => e
              safe_finish_probe(coordinator: coordinator, instance_id: instance_id)
              handle_exception(e, level: :warn, operation: 'vllm.actor.cadence_probe',
                                  instance_id: instance_id)
            end

            def handle_reactive_probe(instance_id:, request:)
              state = @instance_states[instance_id]
              return unless state

              coordinator = state[:probe_coordinator]
              return unless coordinator.begin_probe(request: request)

              probe_token = publisher.readiness_probe_started(
                instance_id: instance_id, publisher_token: state[:publisher_token]
              )
              readiness = check_health(instance_cfg: state[:instance_cfg])
              coordinator.finish_probe(request: request)
              report_probe_result(instance_id:, probe_token:, readiness:)
            rescue StandardError => e
              safe_finish_probe(coordinator: coordinator, request: request, instance_id: instance_id)
              handle_exception(e, level: :warn, operation: 'vllm.actor.reactive_probe',
                                  instance_id: instance_id)
            end

            def report_probe_result(instance_id:, probe_token:, readiness:)
              if readiness.ready?
                publisher.readiness_succeeded(instance_id: instance_id, probe_token: probe_token)
              else
                publisher.readiness_failed(
                  instance_id: instance_id, probe_token: probe_token, reason: readiness.reason
                )
              end
            end

            def build_probe_enqueue(instance_id:)
              proc do |request:|
                handle_reactive_probe(instance_id: instance_id, request: request)
                true
              rescue StandardError => e
                handle_exception(e, level: :warn, operation: 'vllm.actor.probe_enqueue',
                                    instance_id: instance_id)
                false
              end
            end

            def safe_finish_probe(coordinator:, instance_id:, request: nil)
              request ? coordinator&.finish_probe(request: request) : coordinator&.finish_probe
            rescue StandardError => e
              handle_exception(e, level: :warn, operation: 'vllm.actor.finish_probe',
                                  instance_id: instance_id)
            end

            def remove_all_instances
              return unless @instance_states

              @instance_states.each do |instance_id, state|
                publisher.remove_instance(
                  instance_id: instance_id, publisher_token: state[:publisher_token]
                )
              rescue StandardError => e
                handle_exception(e, level: :warn, operation: 'vllm.actor.remove_instance',
                                    instance_id: instance_id)
              end
              @instance_states.clear
            end
          end

          # ── Discovery actor ───────────────────────────────────────────────

          # SSOT v3 periodic discovery actor for vLLM provider instances.
          # Claims instances, discovers models via /v1/models, probes health
          # via /health, and publishes complete OfferingDraft snapshots through
          # the Inventory::Publisher.
          class DiscoveryRefresh < Legion::Extensions::Actors::Every
            include DiscoveryRefreshEvidenceBuilders
            include DiscoveryRefreshValueEvidenceHelpers
            include DiscoveryRefreshConfigHelpers
            include DiscoveryRefreshHealthHelpers
            include DiscoveryRefreshOfferingHelpers
            include DiscoveryRefreshActivationHelpers
            include DiscoveryRefreshRefreshHelpers
            include Legion::Extensions::Helpers::Lex
            include Legion::Logging::Helper

            def self.every_seconds = 300

            def runner_class    = self.class
            def runner_function = 'manual'
            def run_now?        = true
            def use_runner?     = false
            def check_subtask?  = false
            def generate_task?  = false

            def time
              self.class.every_seconds
            end

            def manual
              if @initialized
                tick_refresh
              else
                initial_discovery
                @initialized = true
              end
            rescue StandardError => e
              handle_exception(e, level: :warn, operation: 'vllm.actor.discovery_refresh')
            end

            def shutdown
              remove_all_instances
            rescue StandardError => e
              handle_exception(e, level: :warn, operation: 'vllm.actor.discovery_refresh.shutdown')
            end

            private

            def publisher
              @publisher ||= Legion::Extensions::Llm::Inventory::Publisher.new(provider_family: :vllm)
            end
          end

          # ── Callable ─────────────────────────────────────────────────────

          # Callable wrapper for a vLLM provider instance. Implements the
          # `disconnect` and `normalize_dispatch_error(error:)` contracts
          # required by Inventory::CallableHandle and Routing::ProviderOutcome.
          class VllmCallable
            def initialize(instance_cfg:, logger:)
              @instance_cfg  = instance_cfg
              @logger        = logger
              @disconnected  = false
            end

            def disconnected?
              @disconnected
            end

            def disconnect
              @disconnected = true
              @logger.debug { '[vllm][callable] disconnected' }
            end

            def normalize_dispatch_error(error:)
              reason = error.message.to_s[0, 512]
              kind   = classify_dispatch_error(error: error)
              Legion::Extensions::Llm::Routing::ProviderOutcome.new(
                kind: kind, reason: reason.empty? ? 'unknown dispatch error' : reason
              )
            end

            private

            def classify_dispatch_error(error:)
              case error
              when Faraday::ConnectionFailed then :connection_failure
              when Faraday::TimeoutError     then :timeout
              when Faraday::ClientError      then classify_client_error(error: error)
              when Faraday::ServerError      then classify_server_error(error: error)
              else                                :provider_error
              end
            end

            def classify_client_error(error:)
              status = error.respond_to?(:response_status) ? error.response_status : nil
              case status
              when 401 then :authentication
              when 403 then :authorization
              when 404 then :model_missing
              when 429 then :rate_limited
              else          :invalid_request
              end
            end

            def classify_server_error(error:)
              status = error.respond_to?(:response_status) ? error.response_status : nil
              body   = vllm_response_body(error: error)
              return :instance_unavailable if explicit_vllm_offline?(status: status, body: body)

              case status
              when 503, 529 then :overloaded
              else               :provider_error
              end
            end

            def vllm_response_body(error:)
              return '' unless error.respond_to?(:response) && error.response.is_a?(Hash)

              error.response[:body].to_s.downcase
            end

            # An explicit flat vLLM service-offline body (never just HTTP 503 alone).
            # connection_failure, timeout, overload, 429, and generic 5xx are
            # request-local per §8 and must not map to instance_unavailable.
            def explicit_vllm_offline?(status:, body:)
              status == 503 && (
                body.include?('instance not available') ||
                body.include?('server is going offline') ||
                body.include?('service unavailable, server offline')
              )
            end
          end
        end
      end
    end
  end
end
