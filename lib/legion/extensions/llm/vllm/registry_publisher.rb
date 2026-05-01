# frozen_string_literal: true

module Legion
  module Extensions
    module Llm
      module Vllm
        # Best-effort publisher for vLLM provider availability events.
        class RegistryPublisher
          include Legion::Logging::Helper if defined?(Legion::Logging::Helper)

          APP_ID = 'lex-llm-vllm'

          def initialize(builder: RegistryEventBuilder.new)
            @builder = builder
          end

          def publish_readiness_async(readiness)
            log.info { 'publishing readiness event to llm.registry' }
            schedule { publish_event(@builder.readiness(readiness)) }
          end

          def publish_models_async(models, readiness:)
            log.info { "publishing #{Array(models).size} model event(s) to llm.registry" }
            schedule do
              Array(models).each do |model|
                publish_event(@builder.model_available(model, readiness:))
              end
            end
          end

          private

          def schedule(&)
            return false unless publishing_available?

            Thread.new do
              Thread.current.abort_on_exception = false
              yield
            rescue StandardError => e
              handle_exception(e, level: :debug, handled: true, operation: 'vllm.registry.schedule_thread')
            end
          rescue StandardError => e
            handle_exception(e, level: :debug, handled: true, operation: 'vllm.registry.schedule')
            false
          end

          def publish_event(event)
            return false unless publishing_available?

            message_class.new(event:, app_id: APP_ID).publish(spool: false)
          rescue StandardError => e
            handle_exception(e, level: :warn, handled: true, operation: 'vllm.registry.publish_event')
            false
          end

          def publishing_available?
            return false unless registry_event_available?
            return false unless transport_message_available?
            return true unless defined?(::Legion::Transport::Connection)
            return true unless ::Legion::Transport::Connection.respond_to?(:session_open?)

            ::Legion::Transport::Connection.session_open?
          rescue StandardError => e
            handle_exception(e, level: :debug, handled: true, operation: 'vllm.registry.publishing_available?')
            false
          end

          def registry_event_available?
            defined?(::Legion::Extensions::Llm::Routing::RegistryEvent)
          end

          def transport_message_available?
            return true if message_class_defined?
            return false unless defined?(::Legion::Transport::Message) && defined?(::Legion::Transport::Exchange)

            require 'legion/extensions/llm/vllm/transport/messages/registry_event'
            message_class_defined?
          rescue LoadError => e
            handle_exception(e, level: :debug, handled: true, operation: 'vllm.registry.transport_load')
            false
          end

          def message_class_defined?
            defined?(::Legion::Extensions::Llm::Vllm::Transport::Messages::RegistryEvent)
          end

          def message_class
            ::Legion::Extensions::Llm::Vllm::Transport::Messages::RegistryEvent
          end
        end
      end
    end
  end
end
