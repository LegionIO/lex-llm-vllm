# lex-llm-vllm

LegionIO LLM provider extension for [vLLM](https://docs.vllm.ai/).

This gem lives under `Legion::Extensions::Llm::Vllm` and depends on `lex-llm` for shared provider-neutral routing, fleet, and schema primitives.

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
- Full `Legion::Logging::Helper` integration with structured `handle_exception` across all classes

## Defaults

```ruby
Legion::Extensions::Llm::Vllm.default_settings
# {
#   provider_family: :vllm,
#   instances: {
#     default: {
#       endpoint: "http://localhost:8000",
#       tier: :private,
#       transport: :http,
#       usage: { inference: true, embedding: true },
#       limits: { concurrency: 8 }
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
bundle exec rspec
bundle exec rubocop
```

## License

MIT
