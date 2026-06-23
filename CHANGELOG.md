# Changelog

## [0.8.0] - 2026-06-22

### Changed
- **Architecture overhaul:** Table-owning runners (Conversations, Messages, Requests, Responses, Metrics, RouteAttempts, ContextAccountingEvents) each own their table with `fetch(id:, uuid:, ref:)` and `find_or_create` backed by bidirectional Legion::Cache.
- Prompts and Metering are now pure orchestrators — they call table-owning runners instead of touching models directly.
- Tools, Escalations, Skills wired to use `Conversations.fetch(ref:)` and `Responses.fetch(request_id:)` instead of raw model lookups.
- Deleted entire `helpers/` directory (14 files, -2938 lines) — only `helpers/identity_resolution.rb` remains.
- Removed SubscriptionActor, PersistenceLogging, ResponseMessageLinking, Decryption, Json wrapper, Retention helper, Queries helper.
- Transport base class handles decryption — no decrypt code in ledger.
- Added `legion-cache` dependency for hot-path lookup caching.

### Fixed
- Eliminated 6+ unnecessary DB round-trips per message (Model[id] reloads after create).
- Conversation/Request/Response lookups now cached bidirectionally — second message in same conversation skips DB entirely.

## [0.7.8] - 2026-06-22

### Changed
- Remove ledger spool handling from the active runtime path so prompt and metering consumers rely on broker retry semantics instead of local drain logic.
- Align prompt and metering subscription actors with kwargs-based `insert` runner entrypoints.

### Fixed
- Repair the extracted lifecycle helper flow so prompt-first, metering-first, and redelivery paths reuse existing request/response rows correctly.
- Route collision and helper rescue handling through `handle_exception` while keeping full-suite RSpec and RuboCop clean.

## [0.7.7] - 2026-06-20

### Changed
- Cleaned up the official ledger write path to use `legion-data` LLM model classes for the hottest request/response/metric/tool lookups instead of raw `db[:table]` probes.
- Split request reference resolution into explicit request refs, correlation fallback, and one generated-per-write fallback so the writer no longer hides that flow behind a single opaque expression.
- Bootstrapped `Legion::Data::Models` on demand inside the ledger writer/tool runner so the same path works under the lightweight spec harness and the normal runtime.

## [0.7.6] - 2026-06-20

### Fixed
- Mirror the `Subscription` DSL `consumers` accessor in the lightweight test harness so the metering actor loads under spec without depending on the full Legion runtime.

## [0.7.5] - 2026-06-16

### Changed
- Dependency updates and code quality improvements.

## [0.7.4] - 2026-06-16

### Added
- **Context token accounting persistence** — `OfficialRecordWriter` maps all context accounting fields from `legion-llm` payloads to `llm_message_inference_metrics` columns. `llm_message_inference_metrics` is the canonical source of truth for all pipeline context token metrics.
- **Context accounting event rows** — Detailed per-component accounting events persisted to `llm_context_accounting_events` as drill-down evidence (not a second source of token truth).
- **Prompt/metering ordering enrichment** — When a richer accounting payload arrives via a later event, the existing metric row is enriched using ranked status precedence (`missing` < `profile_skipped` < `partial` < `estimated` < `provider_reconciled`).

## [0.7.3] - 2026-06-15

### Changed
- Persist official inference `request_json`, `response_json`, and `response_thinking_json` with pretty formatting when stored in text columns, while preserving minified JSON for operational fields and hashes.

## [0.7.2] - 2026-06-13

### Changed
- **Gemfile cleanup** — Remove local path overrides; dependencies resolve from gemspec via rubygems.
- **Dependency bump** — Require `lex-llm >= 0.5.0` for canonical types support.
- 135 examples, 0 failures; 83 files, 0 rubocop offenses.

## [0.7.1] - 2026-06-11

### Fixed
- **IDENTITY-07**: `OfficialRouteAttemptWriter` called non-existent `CallerIdentity.resolve_principal_id` and `CallerIdentity.resolve_identity_id`. Delegated to `OfficialRecordWriter.caller_identity_refs` which already implements full identity resolution with header fallbacks and DB lookups.

## [0.7.0] - 2026-06-09

### Fixed
- **ASYNC-RACE-01**: Resolved race condition between metering and prompt audit messages causing duplicate response rows and stale `"{}"`/`"null"` JSON placeholders. Added response UUID fallback to `message_inference_request_id` lookup to enrich metering-created shells instead of creating duplicates.
- **RECONCILIATION-01**: Fixed `UniqueConstraintViolation` in `link_orphaned_tool_calls` by recalculating `tool_call_index` based on existing max index before linking, preventing index collisions.
- **ENRICHMENT-01**: Implemented strict upsert guards (`upsert_guard?`) to prevent overwriting valid data with `nil`, `''`, or `'{}'`. Centralized validation across `update_if_missing` and `update_if_placeholder`.
- **PAYLOAD-01**: Updated `request_payload`, `visible_response`, and `thinking_response` to return `nil` instead of `{}` when content is missing. Insert paths now write `nil` to JSON columns, preventing `"{}"` or `"null"` string artifacts.
- **ENRICHMENT-02**: Expanded `update_if_placeholder` to recognize both `'{}'` and `'null'` as stale markers for retroactive cleanup. Guarded `response_content(body)` against `nil` returns.

## [0.6.0] - 2026-05-31

### Added
- **Skills audit actor** — new queue `llm.audit.skills`, actor, and runner consuming `audit.skill.#` events from the `llm.audit` exchange. Creates `llm_skill_events` records.
- **Escalation audit actor** — new exchange `llm.escalation` binding, queue `llm.audit.escalations`, actor, and runner. Creates `llm_escalation_events` records.
- **Retention purge actor** — actively deletes expired records (hourly, batched). Enforces `session_only` and PHI TTL retention policies that were previously passive.
- **Reconciliation actor** — links orphaned tool calls (null `response_id`) and metering requests (null `latest_message_id`) within a 5-minute lookback window every 2 minutes.
- **Migration 013** — `parent_request_id` FK on requests, `schema_version` on all official tables, `pii_types_json` and `jurisdictions_json` on conversations.
- **Migration 014** — creates `llm_skill_events` and `llm_escalation_events` tables.
- **PHI field-level encryption** — `request_json`, `response_json`, `response_thinking_json` encrypted at rest via `Legion::Crypt` when `contains_phi: true`.

### Fixed
- **LEDGER-01**: `session_only` retention maps to 0 days (immediate expiry) instead of `nil`, distinguishing it from `permanent`.
- **IDENTITY-05**: `CallerIdentity.normalize` recognizes transport identity headers (`x-legion-identity-canonical-name`, `x-legion-identity-kind`, `x-legion-identity-db-*`).
- **IDENTITY-06**: `OfficialRecordWriter.caller_identity_refs` falls back to pre-resolved AMQP header IDs.
- **GAP-06**: `ProviderStats#health_report` uses `recorded_at` instead of `inserted_at` for 24h window.
- **GAP-10**: Backfill `metering_payload` maps `provider_instance` from correct column.
- **GAP-11**: Backfill `registry_reason` extracts from metadata JSON instead of storing raw blob.
- Dead `Retention.resolve` call removed from tools runner.

### Changed
- **Jurisdictions** stored as JSON array instead of comma-joined string.
- **Classification level** validated against controlled vocabulary (`public`/`internal`/`confidential`/`restricted`), defaults to `internal`.
- **Schema version** written to all official table inserts (constant `SCHEMA_VERSION = 13`).
- All CallerIdentity-resolved payloads now pass `__header_principal_id`/`__header_identity_id` for direct FK resolution.

### Requires
- legion-data >= 1.8.9 (migrations 013-014)

## [0.5.0] - 2026-05-26

### Changed
- Tool audit writes no longer dead-letter when the parent response row is missing. The runner retries up to 3 times (1s delay each, configurable via `tool_write` settings), then inserts with a NULL `message_inference_response_id` instead of raising `UnrecoverableMessageError`.
- Removed `ResponseNotReady` exception class — tool calls are always persisted now.
- Populate `conversation_id` FK on `llm_tool_calls` from the message payload/headers, providing conversation-level traceability even when the response FK is NULL.
- Retry configuration moved to `default_settings[:tool_write]` (`response_retry_attempts`, `response_retry_delay`) — tunable at runtime without code changes.

### Requires
- legion-data >= 1.8.9 (migrations 116-117)

## [0.4.3] - 2026-05-22

### Fixed
- Persist `llm.registry.availability` publisher identity from current transport headers into `llm_registry_availability_records`, including best-effort `identity_principal_id` and `identity_id` from DB id headers.
- Preserve legacy identity header and body fallbacks for registry availability records when current transport identity headers are absent.

## [0.4.2] - 2026-05-22

### Fixed
- Dead-letter tool audit messages with missing parent response rows via `UnrecoverableMessageError` so the subscription rejects the RabbitMQ delivery with `requeue: false` instead of acknowledging, republishing, or blocking inside a runner-local sleep/retry loop.
- Set the `llm.registry.availability` subscription actor prefetch to 4 so registry availability events can drain with modest concurrency.

## [0.4.1] - 2026-05-18

### Fixed
- Tool write retries once after 1s when parent response row is not yet committed (race between async metering publish and tool audit AMQP delivery)
- Raises `ResponseNotReady` instead of silently returning nil when response row is missing


## [0.4.0] - 2026-05-17

### Changed
- Rewrite `Runners::Tools` to write tool audit events to the official `llm_tool_calls` and
  `llm_tool_call_attempts` tables instead of the legacy `llm_tool_records` table.
- Each tool audit event produces one `llm_tool_calls` row (linked to the parent
  `llm_message_inference_responses` row) and one `llm_tool_call_attempts` row containing
  the execution outcome.
- Argument and result payloads are stored as SHA-256 fingerprints in `arguments_ref` /
  `result_ref` (the official schema columns are 255-char refs, not full JSON blobs).
- Idempotency is enforced via UUID derived from `tool_call.id` (or request/message context);
  a second write for the same tool call returns `{ result: :duplicate }`.
- Tool call writes that cannot be linked to an existing inference response are logged at
  `warn` and dropped gracefully (returns `{ result: :ok }`).
- Populate `identity_canonical_name` on every insert in `OfficialRecordWriter`:
  `llm_conversations`, `llm_messages` (user and assistant), `llm_message_inference_requests`,
  `llm_message_inference_responses`, and `llm_message_inference_metrics`.
- Populate `identity_principal_id` and `identity_id` on inserts into `llm_messages`,
  `llm_message_inference_responses`, and `llm_message_inference_metrics`.
- Backfill `identity_canonical_name` in `enrich_request!` and `enrich_response!` when the
  enrichment opportunity arrives after a metering-first write.
- `Runners::Tools` extracts identity via `CallerIdentity.normalize` and writes
  `identity_canonical_name`, `identity_principal_id`, and `identity_id` to both
  `llm_tool_calls` and `llm_tool_call_attempts`.
- `Runners::RegistryAvailability` writes `identity_canonical_name` from AMQP headers or
  body identity fields when present; `identity_principal_id` and `identity_id` FK columns
  are not resolved because node/service identities may not be registered in identity tables.

## [0.3.3] - 2026-05-17

### Fixed
- Extract inline `<think>` / `<thinking>` tags from string responses into `response_thinking_json` at write time instead of leaving them in `response_json`.
- Fall back to `ThinkingExtractor` when `response_thinking` is absent from the audit payload (covers Ollama, vLLM, and OpenAI-compatible gateways that pass thinking inline).
- Guard `finish_reason` and `thinking_response` against `String#dig` TypeError when `body[:response]` is a plain string.

## [0.3.2] - 2026-05-13

### Fixed
- Keep metering-only writes from creating placeholder conversation messages so later prompt audits can attach the real user and assistant messages without sequence collisions.
- Use the request reference as the default inference metric idempotency key so metering and prompt audit events enrich the same metric row.
- Suppress duplicate insert warnings for unique races handled by the official ledger writer while retaining debug-level collision messages.

## [0.3.1] - 2026-05-13

### Fixed
- Recover cleanly when concurrent ledger consumers create the same conversation, request, response, metric, or identity rows.
- Keep duplicate insert recovery inside savepoints so PostgreSQL transactions remain usable after unique constraint races.
- Remove temporary prompt runner debug output while preserving single-message subscription prefetch behavior.

## [0.3.0] - 2026-05-08

### Changed
- Renamed all `portable_identity_*` table references to canonical identity table names (`identities`, `identity_principals`, `identity_providers`).
- Renamed internal methods: `resolve_portable_identity` → `resolve_identity`, `find_or_create_portable_identity` → `find_or_create_identity`.

## [0.2.9] - 2026-05-07

### Fixed
- Prefer current publisher identity payloads and AMQP identity headers over stale `caller.requested_by.id` values when normalizing prompt, metering, and tool audit events.
- Resolve canonical caller identity strings into portable identity provider, principal, and identity rows before writing official inference request foreign keys.
- Store `runtime_caller_type` from explicit type fields instead of identity strings.

## [0.2.8] - 2026-05-07

### Fixed
- Extract caller identity from audit event structure (`identity.identity`, `caller.requested_by.identity`) instead of missing top-level `caller_identity_id` / `caller_principal_id` keys.
- Enrich existing request rows when prompt audit arrives after metering (backfills `caller_identity_id`, `caller_principal_id`, `runtime_caller_type`, `request_json`, `context_message_count`).

## [0.2.7] - 2026-05-07

### Fixed
- Enrich existing inference response rows when a richer payload arrives (prompt audit backfills `response_message_id`, `response_json`, `tier`, `finish_reason` that metering left null).

## [0.2.6] - 2026-05-07

### Fixed
- Add `Legion::Logging::Helper` to `OfficialRecordWriter` so `log` is available in rescue blocks.
- Wrap message inserts in savepoints so PostgreSQL unique constraint violations don't poison the parent transaction and cause `PG::InFailedSqlTransaction` on the fallback query.

## [0.2.5] - 2026-05-06

### Fixed
- Log every successful ledger audit and metric database insert at `info` with safe row context.
- Log duplicate insert failures at `warn` and unexpected insert failures at `error` before returning or re-raising.

## [0.2.4] - 2026-05-06

### Fixed
- Replace generated runner subscription actors with runner-named ledger-owned subscription actors so audit queues are consumed through the ledger decoder.
- Route ledger subscription actor payload decoding through the ledger decoder so encrypted audit messages preserve metadata and missing-IV messages dead-letter before core decryption.

## [0.2.3] - 2026-05-06

### Fixed
- Use the real `legion-json` load contract for ledger JSON parsing and remove root `JSON` fallbacks from runtime code.
- Route retention TTL overrides through extension-scoped Legion settings and add default retention settings metadata.
- Send handled runner/backfill errors through `handle_exception` for structured Legion logging.
- Reject encrypted audit payloads that are missing the required `iv` header before attempting decryption.

## [0.2.2] - 2026-05-06

### Fixed
- Persist official response-message foreign keys, keep generated request references stable within a write, and remove raw payload logging from ledger runners.
- Make legacy backfill counts idempotent and attach legacy tool rows only to existing official inference responses.
- Clarify README cutover status for tool and registry projection tables.

## [0.2.1] - 2026-05-06

### Fixed
- Preserve namespaced caller identities from current LLM audit and metering envelopes instead of storing ambiguous display identities such as `system`.

## [0.2.0] - 2026-05-06

### Changed
- Write prompt audit and metering events into the official `legion-data` LLM lifecycle schema instead of legacy ledger-only tables.
- Move provider stats and usage reporting to official inference request, response, and metric tables grouped by provider, provider instance, model, and operation.
- Bumped the transport dependency floor to `legion-transport >= 1.4.14` for the coordinated fleet envelope sweep.

### Added
- Add official prompt and metering writers plus legacy LLM ledger backfill for prompt, metering, tool, and registry availability records.
- Add a hard stop for legacy-only writer mode after official cutover.

## [0.1.13] - 2026-05-03

### Added
- Add `response_thinking_json` to prompt audit records so provider thinking payloads are stored separately from assistant response content.

## [0.1.12] - 2026-04-28

### Added
- Persist provider-neutral `llm.registry` availability event envelopes for offering, worker, lane, model, runtime, capacity, and health diagnostics
- Add ledger-owned passive `llm.registry` transport exchange, durable registry availability queue, and subscription actor

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
