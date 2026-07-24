# Changelog

## [0.3.14] - 2026-07-24

### Fixed
- **Translator passes `finish_reason` and `usage` through on all streaming chunk types.** vLLM sends `finish_reason` on the same chunk as the last content token. Previously the translator dropped it because the early-return pattern only emitted finish_reason when the delta was empty. Now `text_delta`, `tool_call_delta`, and `thinking_delta` chunks carry `stop_reason` and `usage` when present on the SSE event, enabling the accumulator to capture the real provider signal.

## [0.3.13] - 2026-07-14

### Fixed
- **Streaming dead stop on Qwen with thinking enabled.** `empty_delta?` only checked `delta['reasoning_content']`, missing vLLM's `delta['reasoning']` field. When the final chunk carried `finish_reason: "stop"` alongside a `reasoning` delta, the translator incorrectly treated it as an empty delta and fired the done chunk early — the content phase never started, producing an empty streaming response. Now checks both `reasoning_content` and `reasoning`. Also fixed `wire_metadata` to read from either field for sync responses.

## [0.3.12] - 2026-07-05

### Changed
- Stop_reason mapping now uses the shared `Legion::Extensions::Llm::StopReasonMapping` mixin from lex-llm (>= 0.6.9) instead of a local `VLLM_STOP_REASON_MAP`. The local 3-entry map only recognized `tool_use` and silently fell back to `:end_turn` on the `tool_calls` finish_reason that OpenAI-compatible vLLM actually emits on tool turns — so vLLM tool completions were mis-reported as `end_turn`. The shared vocabulary maps both `tool_calls` and `tool_use` to `:tool_use` (plus `stop`/`end_turn`/`eos`, `length`/`max_tokens`, `stop_sequence`, `content_filter`), and is inherited by every provider so it no longer drifts per gem.

## [0.3.11] - 2026-06-20

### Fixed
- Stub shared registry publishing through `RegistryPublisher#schedule` in specs so async availability-event coverage stays stable after the shared publisher moved off raw `Thread.new`.

## [0.3.10] - 2026-06-20

### Fixed
- Stop bulk-publishing vLLM model availability from `list_models`; discovery now emits one registry event per seen model from the shared `lex-llm` policy-filter path so blocked models stay observable without duplicate publishes.

## [0.3.9] - 2026-06-20

### Changed
- Slow the live discovery refresh cadence from 60 seconds to 300 seconds for vLLM instances; `extensions.llm.vllm.discovery_interval` still overrides the default.

## [0.3.8] - 2026-06-20

### Fixed
- Use the shared `lex-llm` capability override contract for provider, instance, and model settings, with canonical capability normalization for embedding/tool/thinking routing.

## [0.3.7] - 2026-06-19

### Changed
- Adopt `Legion::Extensions::Llm::Inventory::ScopedRefresher` mixin (lex-llm 0.6.0). Discovery
  refresh actors now write directly to the live `Inventory` catalog via `Inventory.write_lane`.
- Pin `lex-llm >= 0.6.0` and `legion-llm >= 0.14.0` in gemspec.
- Standard `weight: 100` default added to provider instance settings schema.

## 0.3.6 - 2026-06-18

- **Streaming token usage** — request `stream_options: { include_usage: true }` on streaming chat so
  vLLM emits the final usage-only chunk. Streaming responses now carry input/output token counts;
  previously every streamed response reported zero tokens, which blinded metering/cost. Overridable
  per-instance via `config[:stream_token_usage] = false` for a non-conforming OpenAI-compatible
  backend that rejects the field. The chunk parser already handled the trailing `choices: []` usage
  chunk; the gap was only that the request never asked for it.

## 0.3.5 - 2026-06-16

- Extract `vllm_api_key` from `credentials: { api_key: ... }` in instance settings so Bearer auth works with the standard settings layout.
- Fix `Dalli::RingError` crash in `offering_from_model` when cache server is unavailable; cache write is now best-effort.

## 0.3.3 - 2026-06-16

- Dependency updates (concurrent-ruby 1.3.7, faraday 2.14.3, rubocop 1.88.0) and code quality improvements.

## 0.3.2 - 2026-06-15

- **CapabilityPolicy integration** — Optional capabilities default false; use `CapabilityPolicy.resolve` for offerings. Static all-true predicates no longer used for routing truth. Settings overrides at provider/instance/model level supported.

## 0.3.1 - 2026-06-13

- **Gemfile cleanup** — Remove local path overrides; dependencies resolve from gemspec via rubygems.
- **Bug fix** — Restore vLLM streaming; private `ThinkingExtractor` call was killing every text delta.
- **Canonical tool normalization** — Use canonical normalization for tool parameter schemas.
- 155 examples, 0 failures; 17 files, 0 rubocop offenses.

## 0.3.0 - 2026-06-10

- Add canonical provider translator (`Translator`) implementing `render_request`,
  `parse_response`, `parse_chunk`, and `capabilities` per N×N routing design
- Wire provider `render_payload`, `parse_completion_response`, `build_chunk` to
  delegate to translator with legacy Message/Chunk bridge for backward compat
- Declare vLLM quirks: `tool_calls_as_text`, `forced_tool_choice`, `thinking_tags`,
  `streaming_token_usage`
- G18 parameter mapping: max_tokens, temperature, top_p, top_k, stop_sequences,
  seed, frequency_penalty, presence_penalty, response_format
- Qwen-style </think> tag extraction and tool-call synthesis from content text
- Adopt conformance kit (`it_behaves_like 'a canonical provider translator'`)
- Bump lex-llm dependency floor to >= 0.5.0

## 0.2.13 - 2026-06-05

- Fix missing documentation comment on `DiscoveryRefresh` actor (RuboCop Style/Documentation)

## 0.2.12 - 2026-05-29

- Add capabilities `[:completion, :streaming, :vision, :tools]` to `DEFAULT_INSTANCE_TIER` so routing can match vLLM instances by required capability without live discovery

## 0.2.11 - 2026-05-21

- Add `default_transport`/`default_tier` class declarations, remove duplicate instance methods
- Add `model_allowed?` filtering in `discover_offerings`
- Identity headers included via base provider
- api_base reads from settings[:endpoint] fallback


## 0.2.10 - 2026-05-13

- Add `fetch_model_detail` to re-fetch `/v1/models` for `context_window` on a cache miss.
- Pre-warm the model detail cache during offering discovery via `cache_set` using `model_detail_cache_key`.

## 0.2.9 - 2026-05-12

- Route fleet actor load failures through `Legion::Logging::Helper` instead of direct warnings.
- Add debug logging around vLLM instance discovery, fleet worker dispatch, offering construction, payload rendering, and management endpoints.

## 0.2.8 - 2026-05-07

- Read vLLM thinking defaults from the active provider instance config so per-instance `enable_thinking` settings affect chat payloads.

## 0.2.7 - 2026-05-07

- Fix merge order in `discover_instances` so a user-supplied `tier:` in instance config is no longer clobbered by the `:direct` default.
- Infer instance tier from endpoint URL in `normalize_instance_config`: `localhost`/`127.0.0.1`/`::1` → `:local`, any other host → `:direct`. Explicit `tier:` in config still wins.

## 0.2.6 - 2026-05-06

- Load provider-owned fleet actors through the LegionIO subscription base and the canonical vLLM provider root.
- Keep fleet runners anchored on the provider root namespace so provider constants and instance discovery are always loaded.
- Normalize configured `endpoint` and `api_base` aliases to `vllm_api_base`.
- Preserve configured transport and tier metadata when vLLM builds routing offerings.
- Gate release publishing on the shared security workflow.

## 0.2.5 - 2026-05-06

- Mark handled vLLM offering-discovery failures as handled when logging through `Legion::Logging::Helper`.
- Refresh README dependency, defaults, and local verification guidance for the `lex-llm >= 0.4.3` fleet responder contract.

## 0.2.4 - 2026-05-06

- Use the shared `lex-llm` fleet provider responder helper for provider-owned fleet workers.
- Remove the runtime `legion-llm` dependency and require `lex-llm >= 0.4.3` for responder-side fleet execution.

## 0.2.3 - 2026-05-06

- Remove require-time provider self-registration; `legion-llm` now owns adapter creation and registry writes from loaded provider discovery metadata.
- Bump dependency floors to `lex-llm >= 0.4.1` and `legion-llm >= 0.9.1`.

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
