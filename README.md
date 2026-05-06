# lex-llm-vllm

LegionIO LLM provider extension for [vLLM](https://docs.vllm.ai/).

This gem lives under `Legion::Extensions::Llm::Vllm` and depends on `lex-llm >= 0.4.3` for shared provider-neutral routing, response normalization, fleet envelopes, responder-side fleet execution, and schema primitives.

Load it with `require 'legion/extensions/llm/vllm'`.

## What It Provides

- `Legion::Extensions::Llm::Provider` registration as `:vllm`
- Shared `Legion::Extensions::Llm::Provider::OpenAICompatible` request and response handling
- Chat requests through `POST /v1/chat/completions`
- Streaming chat with `stream_usage_supported?` for token usage reporting
- Model discovery through `GET /v1/models`
- Embeddings through `POST /v1/embeddings`
- vLLM thinking mode via `chat_template_kwargs` (configurable through `Legion::Settings`)
- Best-effort `llm.registry` readiness and model availability event publishing when transport is loaded
- vLLM management helpers: `/health`, `/version`, `/reset_prefix_cache`, `/reset_mm_cache`, `/sleep`, `/wake_up`
- Normalized OpenAI-compatible capability and modality metadata for discovered models
- Shared fleet/default settings via `Legion::Extensions::Llm.provider_settings`
- Structured `Legion::Logging::Helper` handling for provider discovery and fallback paths

## Defaults

```ruby
Legion::Extensions::Llm::Vllm.default_settings
# {
#   provider_family: :vllm,
#   instances: {
#     default: {
#       endpoint: "http://localhost:8000",
#       tier: :direct,
#       transport: :http,
#       credentials: { api_key: nil },
#       enable_thinking: true,
#       usage: { inference: true, embedding: true, image: true },
#       limits: { concurrency: 1 },
#       fleet: {
#         enabled: false,
#         respond_to_requests: false,
#         capabilities: [:chat, :stream_chat, :embed],
#         lanes: [],
#         concurrency: 1,
#         queue_suffix: nil
#       }
#     }
#   }
# }
```

## Configuration

```ruby
Legion::Extensions::Llm.configure do |config|
  config.vllm_api_base = "http://localhost:8000"
  config.vllm_api_key = ENV["VLLM_API_KEY"]
  config.default_model = "meta-llama/Llama-3.1-8B-Instruct"
  config.default_embedding_model = "BAAI/bge-base-en-v1.5"
end
```

## Fleet Responder

Provider instances can opt in to consuming Legion LLM fleet requests. The provider-owned fleet actor only starts when at least one configured instance enables `respond_to_requests`, and request execution delegates to `Legion::Extensions::Llm::Fleet::ProviderResponder`.

```yaml
extensions:
  llm:
    vllm:
      instances:
        local:
          fleet:
            enabled: true
            respond_to_requests: true
            capabilities:
              - chat
              - stream_chat
              - embed
```

### Thinking Mode

Enable vLLM thinking mode globally via settings:

```ruby
# In Legion::Settings or settings JSON
{ llm: { providers: { vllm: { enable_thinking: true } } } }
```

Or pass `thinking: { enabled: true }` per-request. When enabled, the provider adds `chat_template_kwargs: { enable_thinking: true }` to the payload and strips `reasoning_effort`.

## Management Endpoints

The provider exposes helpers for vLLM server management:

| Method | Endpoint | Description |
|--------|----------|-------------|
| `health` | `GET /health` | Server health check |
| `version` | `GET /version` | Server version info |
| `reset_prefix_cache` | `POST /reset_prefix_cache` | Clear prefix cache |
| `reset_mm_cache` | `POST /reset_mm_cache` | Clear multimodal cache |
| `sleep(level:)` | `POST /sleep` | Put server to sleep |
| `wake_up(tags:)` | `POST /wake_up` | Wake server up |

## Registry Publishing

When `lex-llm` routing and Legion transport are available, the provider publishes best-effort availability events to the `llm.registry` exchange:

- **Readiness events** on `readiness(live: true)` calls
- **Model availability events** on `list_models` discovery

Publishing is async (background threads) and never blocks the caller. All failures are handled gracefully via `handle_exception`.

## Development

```bash
bundle install
bundle exec rspec --format json --out tmp/rspec_results.json --format progress --out tmp/rspec_progress.txt
bundle exec rubocop -A
```

## License

MIT
