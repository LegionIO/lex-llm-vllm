# lex-llm-vllm

LegionIO LLM provider extension for vLLM.

This gem lives under `Legion::Extensions::Llm::Vllm` and depends on `lex-llm` for shared provider-neutral routing, fleet, and schema primitives.

## What It Provides

- `LexLLM::Provider` registration as `:vllm`
- shared `LexLLM::Provider::OpenAICompatible` request and response handling
- chat requests through `POST /v1/chat/completions`
- streaming chat support
- model discovery through `GET /v1/models`
- embeddings through `POST /v1/embeddings`
- vLLM management helpers for `/health`, `/version`, `/reset_prefix_cache`, `/reset_mm_cache`, `/sleep`, and `/wake_up`
- shared fleet/default settings via `Legion::Extensions::Llm.provider_settings`

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
LexLLM.configure do |config|
  config.vllm_api_base = "http://localhost:8000"
  config.vllm_api_key = ENV["VLLM_API_KEY"]
  config.default_model = "meta-llama/Llama-3.1-8B-Instruct"
  config.default_embedding_model = "BAAI/bge-base-en-v1.5"
end
```

vLLM's OpenAI-compatible server supports the chat completions, models, and embeddings APIs when the served model and task support them. Chat requests require a model with a chat template; embedding requests require an embedding-capable served model.
