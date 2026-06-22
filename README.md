# lex-llm-ledger

LLM observability persistence for LegionIO. Consumes metering and audit messages from
AMQP queues, decrypts audit payloads, enforces retention policies, and writes official
`legion-data` LLM lifecycle records for usage reporting and compliance.

## Queues Consumed

| Queue | Exchange | Binding | Content |
|---|---|---|---|
| `llm.metering.write` | `llm.metering` (topic) | `metering.#` | Cleartext token/cost metrics |
| `llm.audit.prompts` | `llm.audit` (topic) | `audit.prompt.#` | Encrypted prompt+response pairs |
| `llm.audit.tools` | `llm.audit` (topic) | `audit.tool.#` | Encrypted tool call records |

## Official Tables

- `llm_conversations` - Conversation container and retention/classification metadata
- `llm_messages` - Model-visible user and assistant messages
- `llm_message_inference_requests` - Operation, correlation, request payload, and policy context
- `llm_message_inference_responses` - Provider, provider instance, model, dispatch path, visible response, and thinking payload
- `llm_message_inference_metrics` - Tokens, latency, cost, and finance allocation
- `llm_tool_calls` - Provider-requested tool call lineage
- `llm_registry_events` - Provider/model availability events

Prompt and metering consumers write the official lifecycle tables directly.
`llm_tool_records` and `llm_registry_availability_records` remain operational
projection tables while the official tool/registry event cutover continues.
The legacy backfill reconciles those rows into `llm_tool_calls` and
`llm_registry_events` when they can be linked to official inference responses.
Legacy-only prompt/metering writer mode hard-stops instead of silently writing
stale projections.

## Event Spine Target

The existing tables are useful reporting projections, but the uplift target is end-to-end visibility for every LLM-related lifecycle event. Ledger should add a canonical `llm_events` stream/table and keep `metering_records`, `prompt_records`, and `tool_records` as specialized query views or companion tables.

Every event should share these correlation keys:

- `conversation_id`
- `request_id`
- `exchange_id`
- `message_id`
- `parent_message_id`
- `message_seq`
- `correlation_id`
- `trace_id`
- `span_id`
- `event_id`
- `event_seq`

Event types should cover at least:

- request received, normalized, classified, enriched, and context-assembled
- routing candidates built, candidates excluded, offering selected, failover attempted, escalation attempted
- provider request started, provider response received, provider error/timeout/cancel
- response normalized, streamed chunk emitted, final response returned
- MCP/tool call planned, started, completed, failed, denied, or timed out
- fleet request published, broker accepted/unroutable, worker accepted, worker rejected, fleet response received
- metering emitted, audit emitted, ledger write queued, ledger write succeeded/failed, retry/dead-letter outcome

This lets operators reconstruct a conversation without replaying prompt bodies. Example: conversation `123` had 32 messages, one failed, five executed on Anthropic direct, four locally, the rest on GPU fleet, with per-step response time, token totals, cost allocation, and failover history.

Ledger has three distinct outputs:

1. **Legal/evidence reconstruction** - immutable, correlated, retention-controlled event evidence sufficient to answer a legal or security request. This favors completeness, ordering, integrity, and capture-mode correctness.
2. **Operational analytics** - structured projections for high-level patterns, cost, latency, quality, routing behavior, fleet utilization, tool usage, and failure rates. This favors queryability and aggregation without requiring raw prompt bodies.
3. **Governed training/evaluation datasets** - policy-approved derived datasets for model improvement, team/org use-case tuning, eval generation, routing-quality analysis, and tool-use learning. This must be derived from ledger events through explicit consent, classification, redaction/de-identification, retention, and export controls.

Training/eval export is not automatic reuse of raw audit. A future dataset builder should select eligible events, apply redaction and capture-mode policy, preserve provenance back to `event_id`/`conversation_id`, and write a dataset manifest that records data classes, consent basis, source filters, transform versions, and approval state.

## Key Design Decisions

- **Consumer only** - never publishes to any exchange
- **Passive exchange references** - does not declare `llm.metering` or `llm.audit` (owned by legion-llm)
- **DecryptionUnavailable causes NACK** - messages requeue until the node has Vault credentials
- **PHI TTL cap** - records flagged `contains_phi` are capped at 30 days regardless of retention label
- **Idempotent official writes** - duplicate request/response/message references resolve to existing official rows

## Routing Uplift Target

The 2026-04-25 `legion-llm` routing redesign moves routing to operation-aware model offerings. Ledger should persist the enriched metadata published by `legion-llm` without owning routing policy.

Target metering, prompt, and tool records should be able to store:

- selected offering identity: `offering_id`, `provider_family`, `instance_id`, `canonical_model`, `provider_model`, `operation`, `transport`, `region`, `endpoint_hash`
- routing details: requested route, selected route, excluded candidates, lateral failover chain, vertical escalation chain, and policy decisions
- identity details: caller principal/canonical name/kind/source, accepting runtime identity, executing runtime identity for fleet requests, fleet lane, fleet class, network boundary, placement policy, fleet correlation ID, hashed reply target, and credential lease/grant metadata
- token and cost allocation: conversation ID, input/output/total tokens, selected-offering cost, pricing tier, configured baseline/comparable provider cost, avoided cost, and aggregation keys for tier, fleet class, provider family, instance, model, transport, and lane
- compliance details: `contains_pii`, `contains_phi`, `contains_pci`, `data_classes`, `jurisdictions`, `retention_policy`, and `capture_mode`
- model provenance: management state, model depot registry ID, artifact digest, signature verification status, rollout ring, and approval state
- tool provenance: source type/server, policy tags, approval/denial state, redacted or hashed resource identifiers, and input/output classification flags
- registry/availability events: worker heartbeat, lane availability, offering availability, model sync state, degraded/draining/blocked transitions, and capacity changes from `llm.registry`

The uplift must validate the existing runners and migrations against this target. Current tables already capture core metering, prompt audit, and tool audit, but they need additional correlation fields, routing/offering fields, token context fields, cost allocation fields, identity/fleet fields, and event-spine coverage for request/response/MCP lifecycle events that are not prompt or tool records.

Audit capture modes expected from `legion-llm`:

- `none` - do not publish prompt/tool body audit
- `metadata_only` - store routing/classification/token/cost metadata only
- `redacted` - store redacted bodies plus redaction metadata
- `encrypted_raw` - store encrypted full payloads for approved consumers
- `raw` - plaintext full payloads for local/dev or explicitly approved environments

Prompt/tool audit should be durable. If transport is unavailable, `legion-llm` should rely on durable broker semantics or fail closed upstream when policy requires durable audit; ledger does not spool audit locally.

For async `:fleet` inference, ledger records should preserve the original caller identity and record both runtimes: the process that accepted/enqueued the request and the worker process that executed the provider call. Fleet records should also persist the selected lane, worker fleet class (`endpoint`, `datacenter`, `cloud_vpc`, etc.), placement policy, and model provenance so investigators can tell whether a request ran on the caller's own machine, another endpoint, a datacenter GPU, or a cloud-adjacent worker. The raw RabbitMQ `reply_to` queue should remain transport-only; persisted records should use a stable hash plus the `correlation_id` for reconstruction.

Fleet registry history should arrive through RabbitMQ rather than endpoint workers writing directly to the database. `legion-llm` and provider workers publish availability events to `llm.registry`; ledger consumes those events and persists durable history for operator diagnostics, audit, and legal reconstruction.

Ledger should be able to answer spend-allocation questions without replaying raw prompts: how many input/output tokens a conversation used, how tokens split across Anthropic direct versus fleet GPU versus endpoint MacBook fleet, and estimated dollars saved by local/fleet execution compared with a configured cloud/frontier baseline.

Ledger is not on the LLM execution critical path. If the database is unavailable, ledger consumers should retry or dead-letter through RabbitMQ transport policy while `legion-llm` continues routing and executing requests. Compliance profiles that require durable audit before response are the explicit exception and should fail closed upstream with a clear policy error.

## Requirements

- `legion-data` >= 1.8.0 (official LLM lifecycle schema)
- `legion-json` >= 1.2 (JSON serialization)
- `legion-logging` >= 1.3 (structured exception logging)
- `legion-settings` >= 1.3 (extension-scoped retention settings)
- `legion-transport` >= 1.4.14 (AMQP transport)
- `legion-crypt` >= 1.5 (for decrypting audit messages, optional at runtime)

## Configuration

Ledger runs with safe defaults and reads extension settings from
`extensions.llm.ledger`:

```json
{
  "extensions": {
    "llm": {
      "ledger": {
        "retention": {
          "default_days": 90,
          "phi_ttl_days": 30
        }
      }
    }
  }
}
```

`default_days` controls records with the `default` retention label. `phi_ttl_days`
caps PHI records even when the event asks for longer or permanent retention.
Encrypted audit messages must include an `iv` header; missing-IV messages are
rejected as malformed encrypted audit records rather than retried.

## Usage

```ruby
# Metering write (called by Metering actor)
Legion::Extensions::Llm::Ledger::Runners::Metering.insert(payload: payload, metadata: metadata)

# Usage summary
Legion::Extensions::Llm::Ledger::Runners::UsageReporter.summary(period: 'day', group_by: 'provider_instance')

# Budget check
Legion::Extensions::Llm::Ledger::Runners::UsageReporter.budget_check(budget_id: 'budget_q1', budget_usd: 100.0)

# Provider health
Legion::Extensions::Llm::Ledger::Runners::ProviderStats.health_report

# One-time legacy reconciliation
Legion::Extensions::Llm::Ledger::Backfill::LegacyLlmRecords.run
```

## Development

```bash
bundle install
bundle exec rspec
bundle exec rubocop
```

## License

MIT
