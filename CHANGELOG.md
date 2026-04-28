# Changelog

## [0.1.11] - 2026-04-28

### Fixed
- Replace the retired `legion-llm` runtime dependency with `lex-llm`
- Define ledger-owned passive `llm.metering` and `llm.audit` exchange classes for transport bindings

## [0.1.10] - 2026-04-27

### Fixed
- Decode encrypted prompt and tool audit subscription payloads with either string or symbol `iv` headers before dispatch
- Preserve cleartext prompt and tool audit subscription payload handling when audit encryption is disabled
- Preserve AMQP headers and properties when prompt and tool subscription actors call their ledger runners

## [0.1.9] - 2026-04-09

### Fixed
- SpoolFlush runner_function points to `spool_flush` (zero-arg) instead of `write_metering_record` (requires payload)
- Add `Runners::Metering.spool_flush` method that the framework can call on Every actor ticks

## [0.1.8] - 2026-04-09

### Fixed
- SpoolFlush actor adds runner_class/runner_function to satisfy framework base actor const_get resolution

## [0.1.7] - 2026-04-09

### Changed
- Rename module namespace from `Legion::Extensions::LLM::Ledger` to `Legion::Extensions::Llm::Ledger` for framework const_get compatibility
- Add legion-llm dependency to gemspec
- Use legion-llm exchange classes (Legion::LLM::Transport::Exchanges::Metering, ::Audit) instead of local duplicates
- Remove local exchange files in favor of legion-llm originals
- Transport requires legion-llm exchanges with LoadError rescue in entry point
- Transport extend without const_defined? guard (loaded after Core is available)

### Fixed
- Transport additional_e_to_q uses `from:`/`to:`/`routing_key:` keys matching framework bind_e_to_q contract
- Entry point requires wrapped in rescue to prevent silent load failures

## [0.1.4] - 2026-04-09

### Fixed
- Transport additional_e_to_q uses `from:`/`to:`/`routing_key:` keys matching framework bind_e_to_q contract (unreleased)

## [0.1.3] - 2026-04-09

### Fixed
- Extension entry point moved to lib/legion/extensions/llm/ledger.rb for framework auto-discovery
- Use require_relative for internal requires

## [0.1.2] - 2026-04-09

### Added
- Apache 2.0 LICENSE file

## [0.1.1] - 2026-04-09

### Added
- GitHub Actions CI workflow (ci, security, excluded-files, version-changelog, dependency-review, stale, release)

## [0.1.0] - 2026-04-09

### Added
- Initial release of lex-llm-ledger
- Three Sequel migrations: metering_records, prompt_records, tool_records
- Runners::Metering for writing metering events from llm.metering.write queue
- Runners::Prompts for writing decrypted prompt audit records from llm.audit.prompts queue
- Runners::Tools for writing decrypted tool audit records from llm.audit.tools queue
- Runners::UsageReporter for aggregated usage summaries, worker breakdowns, budget checks
- Runners::ProviderStats for provider health reports and circuit breaker summaries
- Helpers::Decryption for encrypted/cs content decoding via Legion::Crypt (2-arg API with IV)
- Helpers::Retention for TTL resolution with PHI cap enforcement (HIPAA compliance)
- Helpers::Queries for shared time-window and latency classification utilities
- Transport layer with passive exchange references (llm.metering, llm.audit) and durable queues
- Actor::MeteringWriter, PromptWriter, ToolWriter (Subscription actors)
- Actor::SpoolFlush (Every actor, 60s interval) for draining legion-llm on-disk spool
- DecryptionUnavailable propagates as exception for NACK/requeue (not swallowed)
- Idempotent writes via message_id uniqueness (duplicate inserts return { result: :duplicate })
