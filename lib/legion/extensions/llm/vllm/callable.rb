# frozen_string_literal: true

require 'legion/extensions/llm/routing/provider_outcome'
require 'legion/extensions/llm/vllm/provider'

module Legion
  module Extensions
    module Llm
      module Vllm
        # Callable wrapper for a vLLM provider instance. Implements the
        # `disconnect` and `normalize_dispatch_error(error:)` contracts required
        # by Inventory::CallableHandle and Routing::ProviderOutcome, plus the
        # fleet dispatch operations the coordinator invokes (chat, stream_chat,
        # embed, count_tokens). Each dispatch delegates to a per-instance
        # Vllm::Provider built lazily from the instance config; provider and
        # Faraday errors are NOT rescued here so the coordinator's
        # normalize_dispatch_error can classify them.
        class VllmCallable
          # Keys the base Provider exposes as named kwargs for the completion
          # operations. Anything else the fleet passes is folded into the
          # payload `params` hash.
          COMPLETION_NAMED_KEYS = %i[tools temperature schema thinking tool_prefs headers].freeze
          EMBED_NAMED_KEYS = %i[dimensions headers].freeze

          def initialize(instance_cfg:, logger:)
            @instance_cfg = instance_cfg
            @logger = logger
            @disconnected = false
            @inference_calls = 0
          end

          def call_count
            @inference_calls
          end

          def disconnected?
            @disconnected
          end

          def disconnect
            @disconnected = true
            @provider&.disconnect
            @logger.debug { '[vllm][callable] disconnected' }
          end

          # ── Fleet dispatch operations ──────────────────────────────────────

          def chat(messages:, model:, **rest)
            record_inference
            # Canonical boundary (N x N law): pipeline dispatch delivers
            # Canonical::Message objects only. Hash/legacy shapes are the
            # bypass class — reject loudly, never coerce.
            provider.enforce_canonical_messages!(messages)
            named, params = split_fleet_kwargs(rest, COMPLETION_NAMED_KEYS)
            provider.chat(messages: messages, model: model, params: params, **named)
          end

          def stream_chat(messages:, model:, **rest, &)
            record_inference
            provider.enforce_canonical_messages!(messages)
            named, params = split_fleet_kwargs(rest, COMPLETION_NAMED_KEYS)
            provider.stream_chat(messages: messages, model: model, params: params, **named, &)
          end

          def embed(text:, model:, **rest)
            record_inference
            named, params = split_fleet_kwargs(rest, EMBED_NAMED_KEYS)
            provider.embed(text: text, model: model, params: params, **named)
          end

          def count_tokens(messages:, model:, **rest)
            record_inference
            provider.enforce_canonical_messages!(messages)
            _named, params = split_fleet_kwargs(rest, [])
            provider.count_tokens(messages: messages, model: model, params: params)
          end

          def normalize_dispatch_error(error:)
            reason = error.message.to_s[0, 512]
            kind = classify_dispatch_error(error: error)
            Legion::Extensions::Llm::Routing::ProviderOutcome.new(
              kind: kind, reason: reason.empty? ? 'unknown dispatch error' : reason
            )
          end

          private

          def record_inference
            @inference_calls += 1
          end

          def provider
            @provider ||= Legion::Extensions::Llm::Vllm::Provider.new(@instance_cfg)
          end

          # Split the fleet's **rest into the base Provider's named kwargs and a
          # payload params hash (any passed :params merged with unknown keys).
          def split_fleet_kwargs(rest, named_keys)
            named = rest.slice(*named_keys)
            extra = rest.reject { |key, _| named.key?(key) }
            params = (extra.delete(:params) || {}).to_h.merge(extra)
            [named, params]
          end

          # D17: in production the base Connection's ErrorMiddleware raises
          # Legion::Extensions::Llm::*Error (NOT raw Faraday classes), so this
          # maps the full Llm error set (mirroring base Provider#
          # normalize_dispatch_error) and layers the vLLM offline-body detection
          # on top. Raw Faraday classes are also handled for the direct-HTTP
          # paths that bypass the middleware.
          def classify_dispatch_error(error:)
            case error
            when Legion::Extensions::Llm::OverloadedError then :overloaded
            when Legion::Extensions::Llm::RateLimitError then :rate_limited
            when Legion::Extensions::Llm::UnauthorizedError then :authentication
            when Legion::Extensions::Llm::PaymentRequiredError then :billing
            when Legion::Extensions::Llm::ForbiddenError then :authorization
            when Legion::Extensions::Llm::ContextLengthExceededError then :context_rejected
            when Legion::Extensions::Llm::BadRequestError then :invalid_request
            when Legion::Extensions::Llm::ModelNotFoundError then :model_missing
            when Legion::Extensions::Llm::ModelNotAllowedError then :policy
            when Legion::Extensions::Llm::ServiceUnavailableError
              if explicit_vllm_offline?(status: dispatch_error_status(error:),
                                        body: dispatch_error_body(error:))
                :instance_unavailable
              else
                :provider_error
              end
            when Legion::Extensions::Llm::ServerError then :provider_error
            when Faraday::TimeoutError, Timeout::Error then :timeout
            when Faraday::ConnectionFailed, Errno::ECONNREFUSED, Errno::ECONNRESET, SocketError
              :connection_failure
            when Faraday::ClientError then classify_client_error(error:)
            when Faraday::ServerError then classify_server_error(error:)
            else :provider_error
            end
          end

          def classify_client_error(error:)
            case dispatch_error_status(error:)
            when 401 then :authentication
            when 403 then :authorization
            when 404 then :model_missing
            when 429 then :rate_limited
            else          :invalid_request
            end
          end

          def classify_server_error(error:)
            status = dispatch_error_status(error:)
            return :instance_unavailable if explicit_vllm_offline?(status: status, body: dispatch_error_body(error:))

            case status
            when 503, 529 then :overloaded
            else               :provider_error
            end
          end

          # Read the HTTP status off a dispatch error whether its response is a
          # plain Hash, a Faraday::Response, or a Faraday::Env. Real Faraday
          # errors carry a Faraday::Env (a Struct, NOT a Hash), so a legacy
          # `error.response.is_a?(Hash)` gate would never fire in production.
          def dispatch_error_status(error:)
            return error.response_status if error.respond_to?(:response_status) && !error.response_status.nil?

            response = error.response if error.respond_to?(:response)
            return response.status if response.respond_to?(:status) && !response.status.nil?

            response[:status] if response.respond_to?(:[]) && !response[:status].nil?
          end

          def dispatch_error_body(error:)
            return error.response_body.to_s if error.respond_to?(:response_body) && !error.response_body.nil?

            response = error.response if error.respond_to?(:response)
            return response.body.to_s if response.respond_to?(:body) && !response.body.nil?

            response[:body].to_s if response.respond_to?(:[]) && !response[:body].nil?
          end

          # An explicit flat vLLM service-offline body (never just HTTP 503
          # alone). connection_failure, timeout, overload, 429, and generic 5xx
          # are request-local per §8 and must not map to instance_unavailable.
          def explicit_vllm_offline?(status:, body:)
            status == 503 && (
              body.to_s.downcase.include?('instance not available') ||
              body.to_s.downcase.include?('server is going offline') ||
              body.to_s.downcase.include?('service unavailable, server offline')
            )
          end
        end
      end
    end
  end
end
