# Changelog

## 0.2.2 - 2026-05-06

- Enforce the shared keyword-only `lex-llm` provider contract and accept `health(live:)`.
- Move vLLM defaults back to `Legion::Extensions::Llm.provider_settings` with instance-level fleet responder settings.
- Read vLLM thinking defaults from the nested provider instance settings shape.
- Serve non-live vLLM offering reads from cached live model discovery instead of probing the configured endpoint.
- Add provider-owned fleet responder actor and runner backed by `legion-llm` fleet policy execution.
- Bump the transport dependency floor to `legion-transport >= 1.4.14`.

## 0.2.1 - 2026-05-03

- Normalize configured `base_url` instance settings to `vllm_api_base` so LegionIO local settings are honored during provider registration.
- Strip a trailing `/v1` from configured vLLM API roots because OpenAI-compatible endpoints append their own `/v1/...` paths.

## 0.2.0 - 2026-05-01

- Add auto-discovery via CredentialSources and AutoRegistration from lex-llm 0.3.0
- Self-register discovered instances into Call::Registry at require-time
- Require lex-llm >= 0.3.0


## 0.1.9 - 2026-04-30

- Adopt base provider contract from lex-llm 0.1.9
- Replace local `RegistryEventBuilder` and `RegistryPublisher` with parameterized base versions
- Delete local `transport/` directory; base gem now ships shared exchange and message classes
- Remove deprecated `Provider.register` call; provider options registered via `Configuration.register_provider_options`
- Simplify `default_settings` to a flat hash (no longer delegates to `ProviderSettings.build`)
- Override `parse_list_models_response` to populate `context_length` from vLLM `max_model_len` field
- Require `lex-llm >= 0.1.9`

## 0.1.8 - 2026-04-30

- Add `Legion::Logging::Helper` to all modules and classes for structured logging
- Replace all bare rescue blocks with `handle_exception` calls for full observability
- Add info-level action logging to Provider key actions (health, readiness, list_models, version)
- Add info-level logging to RegistryPublisher publish methods
- Remove custom `log_publish_failure` method in favor of standard `handle_exception`
- Update README to reflect registry publishing, thinking mode, and management endpoints

## 0.1.7 - 2026-04-30

- Enable stream_usage_supported? for streaming token usage reporting
- Add render_payload override with chat_template_kwargs for vLLM thinking mode
- Add thinking_enabled? setting support from Legion::Settings

## 0.1.6 - 2026-04-28

- Publish best-effort `llm.registry` readiness and discovered-model availability events when transport is loaded.

## 0.1.5 - 2026-04-28

- Require current shared Legion JSON, logging, settings, and LLM extension gems.

## 0.1.4 - 2026-04-28

- Require `lex-llm >= 0.1.4` so OpenAI-compatible model discovery exposes normalized capabilities and modalities.
- Add explicit discovered-model capability mapping for vLLM routing metadata.

## 0.1.3 - 2026-04-28

- Remove the leftover compatibility entrypoint outside the Legion namespace.
- Load specs through the canonical `legion/extensions/llm/vllm` namespace path.
- Keep provider gemspec dependencies scoped to the shared `lex-llm` base gem.

## 0.1.2 - 2026-04-28

- Replace fork-era namespace references with the standard Legion::Extensions::Llm provider contract.
- Remove GitHub-based lex-llm Gemfile fallback so test installs use only a guarded local path or released gem dependency.
- Require lex-llm >= 0.1.3 for the cleaned Legion-native base extension.

## 0.1.1 - 2026-04-27

- Added the vLLM `Legion::Extensions::Llm::Provider` implementation using the shared OpenAI-compatible adapter.
- Moved provider defaults to shared `Legion::Extensions::Llm.provider_settings`.
- Added vLLM OpenAI-compatible endpoint and management helper coverage.
- Removed tracked `Gemfile.lock` and ignored future lockfiles for gem development.

## 0.1.0 - 2026-04-26

- Initial Legion LLM vLLM provider extension scaffold.
