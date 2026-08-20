# Changelog

## [0.4.7] - 2026-08-20

### Changed
- **lex-llm 0.8.0 conformance (SSOT v4 contract cut).** Migrate the provider, callable, and translator to the Canonical-only boundary:
  - The provider render/parse boundaries render FROM canonical values and parse TO canonical types (`Canonical::Response` for sync, `Canonical::Chunk` for streaming); the `to_legacy_message`/`to_legacy_chunk` bridges and the legacy `Llm::Message`/`Llm::Chunk`/`Llm::ToolCall` reconstruction are deleted.
  - `temperature` is no longer a render kwarg (05 O4): the funnel's `Canonical::Params` (or Hash) flows into the vLLM dialect translator, and the edge `schema` folds into `params.response_format` at the render boundary.
  - The callable's `chat`/`stream_chat` adopt the 0.8.0 callable contract (positional canonical messages; temperature travels inside `params`).
  - Streaming tool-call deltas emit the documented fragment shape (`{ id:, name:, arguments: <String fragment>, index: }`) instead of a full `Canonical::ToolCall` with a String `arguments` member (O03a: `arguments` is Hash-only, and the accumulator reads the fragment by symbol keys); the sync tool-call path parses through the ONE shared strict arguments parser (`Responses::ToolArguments.parse!`, 10 U2) — the rescue-to-`{}` tolerance is gone (04 L7: invalid JSON is a contract error).
  - The offerings read path (`discover_offerings`) is served from the SSOT Registry snapshot by the base read path (07 C5); the legacy `offering_from_model` → `Routing::ModelOffering` production path and its filter cache are deleted — the per-gem writer (`Helpers::OfferingBuilder` + `Runners::DiscoveryRefresh`) is the sole publication path.
- Enforce the canonical dispatch boundary end to end: the fleet callable's chat, stream_chat, and count_tokens operations reject plain-Hash messages with a loud ArgumentError instead of silently re-canonicalizing them. The lenient hash re-canonicalization masked the 2026-08-19 hash-bypass defect for 25 failed openai dispatches; it is removed.
- Prompt-cache `cache_control` rides as a first-class `Canonical::Message` member; the vLLM OpenAI-compatible wire render drops it, so the wire format is unchanged.
- Raise the `lex-llm` dependency floor to 0.8.0.
- The local-tree `lex-llm` path dependency in the test group resolves against the 0.8.0 contract cut during development.

### Removed
- `LegacyCoordinatorAdapter` compatibility wiring from the discovery runner (`Inventory::ScopedRefresher` is deleted in lex-llm 0.8.0); the `Inventory::Publisher` is constructed without a compatibility adapter.
- The render-seam `build_canonical_messages` re-check — central enforcement (`Provider#enforce_canonical_messages!` in the `complete` funnel) is the one check point (08 F2).

### Added
- Conformance kit B1–B4 boundary groups run against the production `VllmCallable`: central canonical enforcement (08 F2), canonical outputs asserted by type (05 O5, 08 R2), operation preservation (PR #189 defect class), and no model re-derivation (PR #45 law).
- Cover the canonical boundary in the dispatch-boundary conformance block: the canonical `cache_control` member survives on the message, the wire never leaks it, and plain-Hash input raises at the callable boundary and the `complete` funnel.

## [0.4.6] - 2026-08-19

### Changed
- Publish the immutable four-component lane-weight pair from vLLM discovery and reconcile weight-only changes on the existing module-runner cadence.
- Serialize initial, recovery, replacement, removal, shutdown, and probe publication transitions behind one module-level mutex without adding a Settings callback or operator workflow.
- Track configured-but-unpublished weight keys on the ordinary discovery pass and log each dormant transition once.
- Raise the `lex-llm` dependency floor to 0.7.6; the existing `legion-settings` dependency remains unchanged.

### Fixed
- Compare the offering catalog as a duplicate-preserving multiset of complete contracts while excluding only non-authoritative evidence observation timestamps, preventing both reorder-only churn and accidental duplicate suppression while retaining real evidence and weight changes.
- Complete startup discovery and weight validation before constructing a callable or claiming inventory, so malformed settings leave no orphaned initializing scope and the next valid cadence pass recovers without operator action.
- Use a real in-memory IO sink for the test logger so Ruby 4 cannot fall back to stdout during the file-only RSpec release gate.

### Added
- Cover the complete writer lifecycle, publication races, failure atomicity, dormant-state cycle, and the actual callable's folded-system OpenAI-compatible wire payload.

## [0.4.5] - 2026-08-18

### Fixed
- **Remove synthetic-default discovery suppression and its warning throttle.** The `default` instance now follows the same endpoint-based discovery path as every other configured instance; no synthetic-default skip warning is emitted.

## [0.4.4] - 2026-08-17

### Fixed
- **Single actor registration — the provider module no longer extends Core at file level.** The boot-time recursive submodule walk (gated on `respond_to?(:autobuild)`) no longer sees the provider at preload and skips it, so the gem's own top-level extension load is the sole actor registration — this eliminates the twin-actor double-claim (FencedPublisherError) the double build produced under SSOT v3's Inventory::Registry claim tokens.
- **Multi-message requests carrying the prompt-cache `cache_control` key no longer fail before HTTP.** legion-llm's prompt-cache step injects `cache_control: {type: :ephemeral}` into every ≥2-message request; the canonical message bridge raised `ArgumentError: unknown keyword: :cache_control` in `Message.from_hash` before any HTTP was sent, so every multi-message vLLM request 500ed. The bridge now projects onto the known member set, so the transport-only key is dropped and never leaks onto the wire.
- **Non-UTF-8 (ASCII-8BIT) dispatch error messages no longer mask the original error.** `RecordSupport.sanitized_reason` now coerces to valid UTF-8 instead of raising `ValidationError`, so a real provider error is no longer turned into an unclassifiable retriable 500.
- **Adds dispatch-boundary regression specs** — 2-message `cache_control` sync render, canonical member projection, and the full provider render-to-parse path — proven to fail pre-fix.
- **The synthetic-default skip warn now fires once per boot instead of every discovery tick.** The `action=skip_instance instance=default reason=synthetic_default` WARN fired on every 300s discovery tick — the fleet's noisiest log line, since a provider being unconfigured-for-default is the normal state. It is now throttled to a single warning at first occurrence (the operator signal: `instances.default` is still the unmodified template; set a real config to publish it).

## [0.4.3] - 2026-08-16

### Fixed
- **Instance identity is now the operator's config NAME** — the discovery
  runner previously keyed instances by the derived `host:port/ak:<digest>`
  string. The derived id silently inerted the router's `instances.<name>`
  settings lookups (per-instance tuning, weight, preferred context windows)
  and collapsed distinct config names that share an endpoint. Discovery now
  publishes `InstanceKey.instance_id` = the config name and carries the
  derived `host:port/ak:<digest>` in the secondary `physical_id` field
  (dedup/diagnostics only — it never participates in identity). Two config
  names pointing at the same endpoint stay distinct instances; an endpoint or
  API-key move under a stable name re-claims the instance so the captured
  callable tracks the new endpoint. Zero config changes required.
- **Embedding models now authoritatively exclude chat** — an embedding model
  (`type: embedding` or `capabilities: [embedding]` in the vLLM catalog)
  published `chat: :supported`, so a plain chat request could be misrouted to
  an embedding-only instance. The offering builder now branches operation
  evidence on model type (matching bedrock): embedding models publish
  `chat`/`stream_chat`/`count_tokens` and the non-embedding media operations
  as `:unsupported` and `embed` as `:supported`; chat models are unchanged
  (`chat`/`stream_chat` `:supported`, `embed` `:unsupported`).
- **`tools` capability evidence was permanently `:unknown`** — `resolve_bool_cap`
  returned `:unknown` for every configuration (absent, `enable_tools: true`, or
  `false`), so the router's candidate evaluator never saw a ready candidate for
  any request requiring the `tools` capability and rejected every tool-using
  request (e.g. Claude Code `/v1/messages`) with typed `too_early` (425/529)
  indefinitely. vLLM serves tool calling as an engine capability for every chat
  model and this provider's translator implements the full tool loop, so the
  builder now publishes `tools: :supported` with `:provider_implementation`
  source. An explicit `enable_tools: false` (model level, else instance level)
  remains an operator opt-out expressed as `:unknown` with the matching
  override source — override sources may never carry `:supported` under the
  SSOT v3 tri-state evidence contract.
- **`thinking` capability evidence semantics made explicit** — support is a
  per-model chat-template fact the vLLM catalog does not expose, and a config
  permission is not evidence, so it stays `:unknown` in every configuration
  (override source when `enable_thinking` is set at model/instance level,
  `:default_false` otherwise).

## [0.4.2] - 2026-08-13

### Fixed
- **Removed ALL remaining `rubocop:disable` directives** — zero directives across `lib/` and `spec/`. Every suppressed metric resolved by real refactoring: `translator.rb` split into 9 focused modules (`TranslatorMessageHelpers`, `TranslatorToolCallHelpers`, `TranslatorToolHelpers`, `TranslatorParamHelpers`, `TranslatorThinkingHelpers`, `TranslatorToolCallParseHelpers`, `TranslatorResponseHelpers`, `TranslatorChunkBuilderHelpers`, `TranslatorChunkHelpers`, `TranslatorRenderHelpers`), bringing every class/module under the 100-line limit.
- **Reverted `.rubocop.yml` weakening** — removed `Metrics/ClassLength: Exclude` for `provider.rb` added in prior pass; class genuinely reduced by module extraction.
- **§9 default substitution removed** — `translator.rb` `extract_wire_model` now raises `ArgumentError` when no model is present rather than substituting `'default'`.
- **§1 settings guards removed** — `global_thinking_enabled?` in `provider.rb` no longer uses `defined?(Legion::Settings)` or `Legion::Settings.dig`; replaced with `settings[:enable_thinking]` bracket access.
- **§1 swallowed rescue fixed** — `extract_host_port` in `discovery_refresh.rb` now calls `handle_exception` instead of silently swallowing `URI::InvalidURIError`.
- **Settings-authoritative embedding removed** — `embedding_supported?` in `discovery_refresh.rb` uses only server evidence (`model_data[:type]` or `model_data[:capabilities]`); `instance_cfg:` parameter eliminated.
- **`api_base` correctly navigates instance settings** — reads `settings.dig(:instances, :default, :endpoint)` (the registered default) instead of the non-existent top-level `settings[:endpoint]` key.
- **Ruby constant lexical scope fixed** — `SUPPORTED_PARAMS`, `PARAM_WIRE_KEYS`, and `FALLBACK_STOP_REASON` moved into the modules that reference them (`TranslatorParamHelpers` and `TranslatorChunkHelpers`) so constant lookup works correctly without the including class.
- **`RSpec/SpecFilePathFormat` fixed** — `fleet_worker_spec.rb` moved from `spec/.../vllm/actors/` (plural) to `spec/.../vllm/actor/` (singular) to match the `Actor::FleetWorker` module path.
- **Conformance fixtures updated** — all canonical request fixtures in `lex-llm` now include `"metadata": {"model": "test-fixture-model"}`, required for §9-compliant translators that raise on absent model.

## [0.4.1] - 2026-08-13

### Fixed
- **§8 health firewall enforced in harness and callable.** `instance_unavailable_error` now returns an explicit vLLM offline HTTP 503 response (body contains "server is going offline"); `classify_server_error_ext` detects this specific body text to return `:instance_unavailable`. Connection failures, generic 503s, and timeouts are never promoted to `:instance_unavailable`. Adds a firewall proof test.
- **Removed all `rubocop:disable` directives** from `provider.rb` and the conformance spec. All metrics (AbcSize, ParameterLists, CyclomaticComplexity, PerceivedComplexity, ModuleLength) resolved by extraction instead of suppression.
- **`provider.rb` ParameterLists compliance.** `build_canonical_request` and `render_payload` now use `**opts` passthrough, reducing explicit parameter lists to ≤5.
- **`discovery_refresh.rb` ParameterLists compliance.** `store_instance_state` uses `**opts` for the trailing group of mutable-state params.
- **`DiscoveryRefreshEvidenceBuilders` ModuleLength compliance.** Value-evidence methods (`build_context_evidence`, `build_max_output_evidence`, `build_embedding_dimensions_evidence`, `build_model_revision_evidence`, `build_tokenizer_evidence`, and helpers) extracted to new `DiscoveryRefreshValueEvidenceHelpers` module.
- **Conformance spec `MultipleMemoizedHelpers` compliance.** Removed the file-level `rubocop:disable/enable` wrapper; all four over-limit describe blocks reduced to ≤3 lets per group by converting extras to `def` methods or consolidating into a `setup` hash let.
- **`offering_attrs` uses `provider_instance_id`**, not `config.instance_id` (which does not exist on `Legion::Extensions::Llm::Configuration`).

## [0.4.0] - 2026-08-13

### Changed
- **SSOT v3 provider migration.** Rewrite `DiscoveryRefresh` actor to publish exact vLLM instances through the lex-llm 0.7.0 `Inventory::Publisher` contract. Each configured vLLM server now claims an independent exact `InstanceKey`, builds complete `OfferingDraft` snapshots with honest per-operation evidence, gates selector visibility behind immediate `/health` readiness, and supports probe-cleared exact-instance availability.
- Raise `lex-llm` gemspec floor to `>= 0.7.0`.
- Remove all `Legion::LLM::Call::Registry` reverse references; discovery no longer scans loaded providers through the coordinator.
- Remove `ScopedRefresher` mixin and `compose_id` delimiter lane IDs; use canonical `lane:v1:` SHA-256 framed identity.
- Derive stable InstanceKey per independently addressable vLLM server: normalized `host:port` plus non-secret auth fingerprint.
- Normalize dispatch errors via `ProviderOutcome`; only an explicit flat service-unavailable (never raw 503/timeout/connection error) may return `instance_unavailable`.
- Advertise `exact_offering_v1` fleet execution contract with exact offering/operation/model/instance verification.
- Register `discovery_interval: 300` as a documented extension default; read directly without `.dig`/`||` fallback guards.
- Add comprehensive SSOT v3 conformance specs including the shared `'an SSOT v3 provider adapter'` examples.

## [0.3.17] - 2026-08-04

### Fixed
- Preserve each streamed tool call's wire index when bridging canonical vLLM chunks to legacy chunks, allowing `lex-llm` 0.6.16 to correlate interleaved argument fragments for parallel tool calls instead of attaching them by recency.

## [0.3.16] - 2026-07-31

### Fixed
- **`parse_chunk` now handles multiple tool_calls batched in a single SSE delta.** vLLM can batch several parallel tool_calls into one `choices[0].delta.tool_calls` array. Previously only `tool_calls.first` was processed — the 2nd+ tool calls were silently dropped, causing parallel tool invocations to lose calls. Now returns an array of `tool_call_delta` chunks (one per tool_call), which the streaming handler already iterates (per lex-llm 0.6.13). Single tool_call deltas still return a single chunk (not wrapped in an array) for backward compatibility.

## [0.3.15] - 2026-07-31

### Fixed
- **`to_legacy_chunk` now propagates `stop_reason` from canonical chunks.** The canonical translator correctly parsed vLLM's `finish_reason` into `Canonical::Chunk.stop_reason`, but `to_legacy_chunk` never passed it into the legacy `Legion::Extensions::Llm::Chunk` constructor. The `StreamAccumulator` already reads `chunk.stop_reason` (line 40), so the field was silently nil on every streamed chunk — downstream always defaulted to `:end_turn` regardless of what the provider actually said. Truncated responses (`:max_tokens`) and content-filtered responses (`:content_filter`) were indistinguishable from clean completions. Now the real finish_reason flows through: canonical chunk → legacy chunk → accumulator → assembled Message.

## [0.3.14] - 2026-07-24

### Fixed
- **Translator passes `finish_reason` and `usage` through on all streaming chunk types.** vLLM sends `finish_reason` on the same chunk as the last content token. Previously the translator dropped it because the early-return pattern only emitted finish_reason when the delta was empty. Now `text_delta`, `tool_call_delta`, and `thinking_delta` chunks carry `stop_reason` and `usage` when present on the SSE event, enabling the accumulator to capture the real provider signal.
- **Translator returns both thinking and content when vLLM sends both on the same SSE chunk.** vLLM emits `reasoning` and `content` simultaneously on the boundary between thinking and visible output. Previously the first-branch-wins pattern dropped content when reasoning was present, causing visible characters to disappear from responses (e.g. numbered list items losing their leading digit). `parse_chunk` now returns an array `[thinking_delta, text_delta]` when both fields are present, and the streaming handler iterates them.

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
