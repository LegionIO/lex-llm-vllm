# lex-llm-vllm

LegionIO LLM provider extension for [vLLM](https://docs.vllm.ai/).

This gem provides a complete vLLM adapter for the LegionIO LLM routing layer. It speaks the OpenAI-compatible API, discovers models at runtime, publishes availability events, and supports vLLM-specific features like thinking mode and server lifecycle management.

**Namespace:** `Legion::Extensions::Llm::Vllm`
**Provider slug:** `:vllm`
**Dependency:** `lex-llm >= 0.4.3`

Load with:

```ruby
require 'legion/extensions/llm/vllm'
```

---

## Architecture at a Glance

```
Legion::Extensions::Llm::Vllm          # Root module (namespace, discovery, defaults)
  |-- Provider                          # Per-instance provider (chat, models, management)
  |     |-- OpenAICompatible (mixin)    # Shared request/response handling
  |     |-- Capabilities (module)       # Capability predicates for offerings
  |
  |-- Actor::DiscoveryRefresh           # Periodic actor: refreshes discovered model list
  |-- Actor::FleetWorker                # Subscription actor: consumes fleet requests
  |
  |-- Runners::FleetWorker              # Runner: delegates to Fleet::ProviderResponder
```

### File Map

| File | What |
|------|------|
| `lib/legion/extensions/llm/vllm.rb` | Root module, `discover_instances`, `default_settings`, alias normalization |
| `lib/legion/extensions/llm/vllm/version.rb` | `VERSION` constant |
| `lib/legion/extensions/llm/vllm/provider.rb` | Provider class, chat/embeddings/model discovery, management endpoints |
| `lib/legion/extensions/llm/vllm/actors/discovery_refresh.rb` | Periodic actor to refresh model discovery cache |
| `lib/legion/extensions/llm/vllm/actors/fleet_worker.rb` | Subscription actor for fleet request consumption |
| `lib/legion/extensions/llm/vllm/runners/fleet_worker.rb` | Runner entrypoint that delegates to `Fleet::ProviderResponder` |

---

## Key Classes

### `Legion::Extensions::Llm::Vllm` (Root Module)

The top-level module. It handles auto-registration via `Legion::Extensions::Llm::AutoRegistration`, instance discovery, and configuration normalization.

**Constants:**
- `PROVIDER_FAMILY` — `:vllm`
- `DEFAULT_INSTANCE_TIER` — `{ tier: :direct, capabilities: [:completion, :streaming, :vision, :tools] }`

**Class methods:**

| Method | Description |
|--------|-------------|
| `default_settings` | Returns the full default settings hash (endpoint, fleet, thinking, etc.) |
| `provider_class` | Returns `Provider` |
| `registry_publisher` | Memoized `Legion::Extensions::Llm::RegistryPublisher` instance |
| `discover_instances` | Probes `localhost:8000` health endpoint, merges configured instances from `Legion::Settings` |
| `normalize_instance_config(config)` | Normalizes config keys (`base_url`/`api_base`/`endpoint` -> `vllm_api_base`), infers tier |
| `normalize_api_base(url)` | Strips trailing `/v1` from URLs |
| `infer_tier_from_endpoint(url)` | Returns `:local` for localhost addresses, `:direct` otherwise |

**Instance discovery sources:**
1. HTTP health probe against `http://localhost:8000` (0.1s timeout) -> `:local` tier
2. Configured instances under `Legion::Settings[:extensions][:llm][:vllm][:instances]`

### `Legion::Extensions::Llm::Vllm::Provider`

The per-instance provider class. Inherits from `Legion::Extensions::Llm::Provider` and mixes in `OpenAICompatible` for shared HTTP request/response handling.

**Class methods:**

| Method | Returns |
|--------|---------|
| `slug` | `'vllm'` |
| `local?` | `false` |
| `default_transport` | `:http` |
| `default_tier` | `:direct` |
| `configuration_options` | `[:vllm_api_base, :vllm_api_key]` |
| `configuration_requirements` | `[]` (no required fields) |
| `capabilities` | `Capabilities` module |
| `registry_publisher` | Delegates to `Vllm.registry_publisher` |

**Instance methods:**

| Method | Description |
|--------|-------------|
| `api_base` | Normalized API root from config, settings, or `http://localhost:8000` |
| `headers` | Identity headers + optional Bearer token |
| `settings` | Returns `Vllm.default_settings` |
| `health(live:)` | `GET /health` |
| `readiness(live:)` | Checks readiness, publishes async readiness event when `live: true` |
| `list_models` | `GET /v1/models`, publishes async model availability events |
| `discover_offerings(live:, **)` | Builds `ModelOffering` instances from discovered models (uses cache when not live) |
| `version` | `GET /version` |
| `fetch_model_detail(model_name)` | Re-fetches `/v1/models` to resolve `context_window` on cache miss |
| `stream_usage_supported?` | Always `true` for vLLM |
| `reset_prefix_cache(reset_running_requests:, reset_external:)` | `POST /reset_prefix_cache` |
| `reset_mm_cache` | `POST /reset_mm_cache` |
| `sleep(level:)` | `POST /sleep` |
| `wake_up(tags:)` | `POST /wake_up` |

**Payload rendering:** Overrides `render_payload` to support vLLM thinking mode via `chat_template_kwargs` and strips `reasoning_effort`.

### `Provider::Capabilities` (Module)

Predicate methods for model capability detection. All return `true` for vLLM by default:

- `chat?(model)`, `streaming?(model)`, `vision?(model)`, `functions?(model)`, `embeddings?(model)`
- `critical_capabilities_for(model)` — returns array of active capability names

### `Actor::DiscoveryRefresh`

Periodic actor (extends `Legion::Extensions::Actors::Every`) that refreshes the vLLM discovered model list.

- **Default interval:** 1800 seconds (30 minutes)
- **Configurable via:** `Legion::Settings[:extensions][:llm][:vllm][:discovery_interval]`
- **Action:** Calls `Legion::LLM::Discovery.refresh_discovered_models!(provider: :vllm)`

### `Actor::FleetWorker`

Subscription actor (extends `Legion::Extensions::Actors::Subscription`) that consumes LLM fleet requests routed to vLLM.

- Only activates when `Fleet::ProviderResponder.enabled_for?` returns true for discovered instances
- Delegates execution to `Runners::FleetWorker.handle_fleet_request`

### `Runners::FleetWorker`

Runner module that dispatches fleet requests to `Legion::Extensions::Llm::Fleet::ProviderResponder` with vLLM-specific context (provider family, class, instance discovery callback).

---

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

---

## Configuration

### Per-instance via Legion::Extensions::Llm.configure

```ruby
Legion::Extensions::Llm.configure do |config|
  config.vllm_api_base = "http://localhost:8000"
  config.vllm_api_key = ENV["VLLM_API_KEY"]
  config.default_model = "meta-llama/Llama-3.1-8B-Instruct"
  config.default_embedding_model = "BAAI/bge-base-en-v1.5"
end
```

### Multi-instance via Legion::Settings

```yaml
extensions:
  llm:
    vllm:
      discovery_interval: 1800  # seconds between model list refreshes
      instances:
        production:
          vllm_api_base: "https://vllm.example.com"
          tier: :direct
        local:
          vllm_api_base: "http://localhost:8000"
          tier: :local
```

### Endpoint alias normalization

The following keys are all resolved to `vllm_api_base` during instance config normalization:
- `base_url`
- `api_base`
- `endpoint`

Trailing `/v1` is stripped automatically.

---

## Fleet Responder

Provider instances can opt in to consuming Legion LLM fleet requests. The fleet actor only starts when at least one configured instance enables `respond_to_requests`.

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

Execution flows: `Actor::FleetWorker` (receives message) -> `Runners::FleetWorker.handle_fleet_request` -> `Fleet::ProviderResponder.call`.

---

## Thinking Mode

vLLM supports a "thinking" mode that enables extended reasoning. Enable via:

**Instance-level:**
```yaml
extensions:
  llm:
    vllm:
      instances:
        default:
          enable_thinking: true
```

**Global:**
```ruby
# Legion::Settings or settings JSON
{ llm: { providers: { vllm: { enable_thinking: true } } } }
```

**Per-request:**
```ruby
# Pass thinking: { enabled: true } in the chat kwargs
```

When enabled, the provider adds `chat_template_kwargs: { enable_thinking: true }` to the chat payload and strips the OpenAI-specific `reasoning_effort` key.

---

## Management Endpoints

| Method | Endpoint | Kwargs | Description |
|--------|----------|--------|-------------|
| `health(live:)` | `GET /health` | `live:` | Server health check |
| `version` | `GET /version` | none | Server version info |
| `reset_prefix_cache` | `POST /reset_prefix_cache` | `reset_running_requests:`, `reset_external:` | Clear prefix cache |
| `reset_mm_cache` | `POST /reset_mm_cache` | none | Clear multimodal cache |
| `sleep(level:)` | `POST /sleep` | `level:` (default: 1) | Put worker to sleep |
| `wake_up(tags:)` | `POST /wake_up` | `tags:` | Wake worker up |

---

## Registry Publishing

When `lex-llm` routing and Legion transport are available, the provider publishes best-effort availability events to the `llm.registry` exchange:

- **Readiness events** on `readiness(live: true)` calls
- **Model availability events** on `list_models` discovery

All publishing is async (background threads) and never blocks the caller. Failures are logged via `handle_exception`.

---

## Model Discovery & Offerings

On `list_models`, vLLM returns `max_model_len` which is mapped to `context_length`. This value is:
1. Attached to `Model::Info` objects
2. Cached via `cache_set` with 86400s TTL keyed by `model_detail_cache_key`
3. Available in routing offerings via `limits: { context_window: ctx }`

`discover_offerings(live: false)` serves from the cached model list without hitting the network.

---

## Development

```bash
bundle install
bundle exec rspec
bundle exec rubocop -A
```

---

## License

MIT
