# Changelog

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
