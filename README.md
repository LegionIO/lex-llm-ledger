# lex-llm-ledger

LLM observability persistence for LegionIO. Consumes metering and audit messages from
AMQP queues, decrypts audit payloads, enforces retention policies, and writes records
to a database for usage reporting and compliance.

## Queues Consumed

| Queue | Exchange | Binding | Content |
|---|---|---|---|
| `llm.metering.write` | `llm.metering` (topic) | `metering.#` | Cleartext token/cost metrics |
| `llm.audit.prompts` | `llm.audit` (topic) | `audit.prompt.#` | Encrypted prompt+response pairs |
| `llm.audit.tools` | `llm.audit` (topic) | `audit.tool.#` | Encrypted tool call records |

## Tables

- `metering_records` - One row per LLM inference (tokens, cost, latency, routing)
- `prompt_records` - Full prompt/response audit with retention TTL and PHI classification
- `tool_records` - Tool call audit linked to parent prompt via correlation_id

## Key Design Decisions

- **Consumer only** - never publishes to any exchange
- **Passive exchange references** - does not declare `llm.metering` or `llm.audit` (owned by legion-llm)
- **DecryptionUnavailable causes NACK** - messages requeue until the node has Vault credentials
- **PHI TTL cap** - records flagged `contains_phi` are capped at 30 days regardless of retention label
- **Idempotent writes** - duplicate message_id inserts are silently dropped

## Requirements

- `legion-data` >= 1.6 (Sequel DB connection)
- `legion-json` >= 1.2 (JSON serialization)
- `legion-transport` >= 1.4 (AMQP transport)
- `legion-crypt` >= 1.5 (for decrypting audit messages, optional at runtime)

## Usage

```ruby
# Metering write (called by MeteringWriter actor)
Legion::Extensions::LLM::Ledger::Runners::Metering.write_metering_record(payload, metadata)

# Usage summary
Legion::Extensions::LLM::Ledger::Runners::UsageReporter.summary(period: 'day', group_by: 'provider')

# Budget check
Legion::Extensions::LLM::Ledger::Runners::UsageReporter.budget_check(budget_id: 'budget_q1', budget_usd: 100.0)

# Provider health
Legion::Extensions::LLM::Ledger::Runners::ProviderStats.health_report
```

## Development

```bash
bundle install
bundle exec rspec
bundle exec rubocop
```

## License

MIT
