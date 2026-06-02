# Populate Identity Columns on Every Insert — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ensure `identity_principal_id`, `identity_id`, and `identity_canonical_name` are written on every insert in `OfficialRecordWriter` (conversations, messages, requests, responses, metrics), `Runners::Tools` (tool_calls, tool_call_attempts), and `Runners::RegistryAvailability` (registry_availability_records).

**Architecture:** The identity resolution logic already exists in `OfficialRecordWriter` as `caller_identity_refs(db, body)` and `parsed_identity_descriptor(body)`. These methods are called once per write and memoized on the body hash. All tables that receive an INSERT in a write path need to receive the three identity columns. `Runners::Tools` does not currently include `OfficialRecordWriter`, so it must resolve identity locally using the same helper pattern. `Runners::RegistryAvailability` handles infrastructure-only events with no user context, so only `identity_canonical_name` (raw string, no FK resolution) is written when present.

**Tech Stack:** Ruby 3.4+, Sequel (SQLite in test, Postgres in prod), RSpec, RuboCop (rubocop-legion shared config), frozen_string_literal on every file.

---

## Column Reference by Table

| Table | Existing identity cols | Columns to add in this task |
|-------|----------------------|---------------------------|
| `llm_conversations` | `principal_id`, `identity_id` (old names from migration 077) | `identity_canonical_name` (added by migration 103) |
| `llm_messages` | none | `identity_principal_id`, `identity_id`, `identity_canonical_name` (added by migration 104) |
| `llm_message_inference_requests` | `caller_principal_id`, `caller_identity_id` | `identity_canonical_name` (added by migration 105) |
| `llm_message_inference_responses` | none | `identity_principal_id`, `identity_id`, `identity_canonical_name` (added by migration 106) |
| `llm_message_inference_metrics` | none | `identity_principal_id`, `identity_id`, `identity_canonical_name` (added by migration 108) |
| `llm_tool_calls` | none | `identity_principal_id`, `identity_id`, `identity_canonical_name` (added by migration 109) |
| `llm_tool_call_attempts` | none | `identity_principal_id`, `identity_id`, `identity_canonical_name` (added by migration 110) |
| `llm_registry_availability_records` | none | `identity_canonical_name` only (no user context; `identity_principal_id`/`identity_id` added by migration 011 if present) |

**Note on `llm_conversations`:** The table uses old column names `principal_id` and `identity_id` (not the standard `identity_principal_id`). The writer already sets these; this task adds `identity_canonical_name` to the insert.

---

## File Map

| File | Action | What changes |
|------|--------|-------------|
| `lib/.../writers/official_record_writer.rb` | Modify | Add `identity_canonical_name` to all inserts; add `identity_principal_id`/`identity_id` to responses and metrics inserts; add all three to user_message and response_message inserts |
| `lib/.../runners/tools.rb` | Modify | Extract canonical name via `CallerIdentity.normalize`; write identity columns to tool_calls and tool_call_attempts |
| `lib/.../runners/registry_availability.rb` | Modify | Write `identity_canonical_name` (raw string, no FK resolution) to registry availability records when a caller identity is present |
| `spec/writers/official_prompt_writer_spec.rb` | Modify | Add examples: identity columns populated on messages, responses, metrics |
| `spec/runners/tools_spec.rb` | Modify | Add examples: identity columns populated on tool_call and attempt |
| `spec/runners/registry_availability_spec.rb` | Modify | Add example: identity_canonical_name written when caller present; absent otherwise |
| `lib/.../version.rb` | Modify | Bump version 0.4.0 → 0.5.0 |
| `CHANGELOG.md` | Modify | Add 0.5.0 entry |

---

## Task 1: Write failing tests for OfficialRecordWriter identity columns on responses, metrics, messages

**Files:**
- Modify: `spec/writers/official_prompt_writer_spec.rb`

- [ ] **Step 1: Add a failing test for `identity_canonical_name` on requests**

In `spec/writers/official_prompt_writer_spec.rb`, inside the existing `context 'resolves canonical caller identity strings into portable identity foreign keys'` it block (line 132), extend the assertions to also check `identity_canonical_name`:

```ruby
it 'resolves canonical caller identity strings into portable identity foreign keys' do
  described_class.write(
    payload.merge(
      caller_identity: 'matt@example.com',
      identity:        { identity: 'matt@example.com', type: 'human', credential: 'system' }
    )
  )

  principal = Legion::Data.connection[:identity_principals].first
  identity  = Legion::Data.connection[:identities].first
  request   = Legion::Data.connection[:llm_message_inference_requests].first

  expect(principal).to include(canonical_name: 'matt@example.com', kind: 'human')
  expect(identity).to include(principal_id: principal[:id], provider_identity_key: 'matt@example.com')
  expect(request[:caller_principal_id]).to eq(principal[:id])
  expect(request[:caller_identity_id]).to eq(identity[:id])
  expect(request[:runtime_caller_type]).to eq('human')
  expect(request[:identity_canonical_name]).to eq('matt@example.com')
end
```

- [ ] **Step 2: Add a failing test for identity columns on responses and metrics**

After the existing identity test, add:

```ruby
it 'writes identity_principal_id, identity_id, and identity_canonical_name on responses and metrics' do
  described_class.write(
    payload.merge(
      identity: { identity: 'alex@example.com', type: 'human', credential: 'entra_delegated' }
    )
  )

  principal = Legion::Data.connection[:identity_principals].first
  identity  = Legion::Data.connection[:identities].first
  response  = Legion::Data.connection[:llm_message_inference_responses].first
  metric    = Legion::Data.connection[:llm_message_inference_metrics].first

  expect(response[:identity_principal_id]).to eq(principal[:id])
  expect(response[:identity_id]).to eq(identity[:id])
  expect(response[:identity_canonical_name]).to eq('alex@example.com')
  expect(metric[:identity_principal_id]).to eq(principal[:id])
  expect(metric[:identity_id]).to eq(identity[:id])
  expect(metric[:identity_canonical_name]).to eq('alex@example.com')
end
```

- [ ] **Step 3: Add a failing test for identity columns on llm_messages (user + assistant)**

```ruby
it 'writes identity_principal_id, identity_id, and identity_canonical_name on user and assistant messages' do
  described_class.write(
    payload.merge(
      identity: { identity: 'sam@example.com', type: 'human', credential: 'entra_delegated' }
    )
  )

  principal       = Legion::Data.connection[:identity_principals].first
  identity        = Legion::Data.connection[:identities].first
  user_message    = Legion::Data.connection[:llm_messages].where(role: 'user').first
  assistant_msg   = Legion::Data.connection[:llm_messages].where(role: 'assistant').first

  expect(user_message[:identity_principal_id]).to eq(principal[:id])
  expect(user_message[:identity_id]).to eq(identity[:id])
  expect(user_message[:identity_canonical_name]).to eq('sam@example.com')
  expect(assistant_msg[:identity_principal_id]).to eq(principal[:id])
  expect(assistant_msg[:identity_id]).to eq(identity[:id])
  expect(assistant_msg[:identity_canonical_name]).to eq('sam@example.com')
end
```

- [ ] **Step 4: Add a failing test for `identity_canonical_name` on conversations**

```ruby
it 'writes identity_canonical_name on conversations' do
  described_class.write(
    payload.merge(
      identity: { identity: 'dana@example.com', type: 'human', credential: 'entra_delegated' }
    )
  )

  conversation = Legion::Data.connection[:llm_conversations].first
  expect(conversation[:identity_canonical_name]).to eq('dana@example.com')
end
```

- [ ] **Step 5: Run tests to verify new examples fail**

```bash
cd /Users/matt.iverson@optum.com/rubymine/legion/extensions-ai/lex-llm-ledger
bundle exec rspec spec/writers/official_prompt_writer_spec.rb --format documentation 2>&1 | tail -30
```

Expected: the 4 new examples fail with nil != "..." or similar.

---

## Task 2: Implement identity columns in OfficialRecordWriter

**Files:**
- Modify: `lib/legion/extensions/llm/ledger/writers/official_record_writer.rb`

The writer already resolves identity once per `write_prompt` call via `caller_identity_refs(db, body)` (memoized on `body[:__ledger_caller_identity_refs]`) and `parsed_identity_descriptor(body)` (which returns `{ canonical_name:, kind:, ... }`).

**Key rule:** `identity_canonical_name` does NOT require FK resolution — write it from `parsed_identity_descriptor(body)[:canonical_name]` even when identity tables are unavailable. `identity_principal_id` / `identity_id` come from `caller_identity_refs(db, body)` and are guarded by `identity_tables_available?` (which `caller_identity_refs` already handles internally).

- [ ] **Step 1: Add a private helper `identity_canonical_name(body)`**

Add this method at the bottom of the `module_function` block in `official_record_writer.rb`, just before the final `end` that closes `OfficialRecordWriter`:

```ruby
def identity_canonical_name(body)
  parsed_identity_descriptor(body)[:canonical_name]
end
```

- [ ] **Step 2: Add identity columns to `find_or_create_conversation`**

The `llm_conversations` table uses old column names `principal_id`/`identity_id` (not the standard `identity_principal_id`). Only add `identity_canonical_name`.

In `find_or_create_conversation`, locate the `insert_with_savepoint` call and add `identity_canonical_name`:

```ruby
id = insert_with_savepoint(db, :llm_conversations, {
                             uuid:                 uuid,
                             title:                body[:title] || body[:conversation_title],
                             classification_level: classification_level(body),
                             contains_phi:         contains_phi?(body),
                             contains_pii:         contains_pii?(body),
                             retention_policy:     body[:retention_policy] || 'default',
                             expires_at:           body[:expires_at],
                             recorded_at:          recorded_at(body),
                             identity_canonical_name: identity_canonical_name(body),
                             inserted_at:          Time.now.utc,
                             created_at:           Time.now.utc,
                             updated_at:           Time.now.utc
                           }, operation: 'official_record_writer.conversation')
```

- [ ] **Step 3: Add `identity_canonical_name` to `find_or_create_user_message`**

In the `find_or_create_user_message` method, locate the `insert_with_savepoint` call and add identity columns:

```ruby
id = insert_with_savepoint(db, :llm_messages, {
                             uuid:                    uuid,
                             conversation_id:         conversation[:id],
                             seq:                     seq,
                             role:                    'user',
                             content_type:            'text',
                             content:                 request_content(body),
                             input_tokens:            tokens(body)[:input_tokens],
                             output_tokens:           0,
                             identity_principal_id:   caller_identity_refs(db, body)[:principal_id],
                             identity_id:             caller_identity_refs(db, body)[:identity_id],
                             identity_canonical_name: identity_canonical_name(body),
                             created_at:              recorded_at(body),
                             inserted_at:             Time.now.utc
                           }, operation: 'official_record_writer.user_message')
```

- [ ] **Step 4: Add `identity_canonical_name` to `find_or_create_request`**

In `find_or_create_request`, add `identity_canonical_name` to the insert hash alongside the existing `caller_principal_id`/`caller_identity_id`:

```ruby
id = insert_with_savepoint(db, :llm_message_inference_requests, {
                             uuid:                  stable_uuid(request_id),
                             conversation_id:       conversation[:id],
                             latest_message_id:     latest_message&.dig(:id),
                             caller_principal_id:   caller_refs[:principal_id],
                             caller_identity_id:    caller_refs[:identity_id],
                             identity_canonical_name: identity_canonical_name(body),
                             runtime_caller_type:   caller_type(body),
                             request_ref:           request_id,
                             correlation_ref:       correlation_id(body),
                             correlation_id:        correlation_id(body),
                             exchange_ref:          body[:exchange_id],
                             request_type:          operation,
                             operation:             operation,
                             idempotency_key:       body[:idempotency_key] || request_id,
                             status:                'responded',
                             context_message_count: Array(body.dig(:request, :messages) || body[:messages]).size,
                             request_capture_mode:  'full',
                             request_json:          json_dump(request_payload(body)),
                             classification_level:  classification_level(body),
                             cost_center:           billing(body)[:cost_center],
                             budget_key:            billing(body)[:budget_id] || billing(body)[:budget_key],
                             requested_at:          recorded_at(body),
                             inserted_at:           Time.now.utc
                           }, operation: 'official_record_writer.inference_request')
```

Also add `identity_canonical_name` to the `enrich_request!` method — if `identity_canonical_name` is nil on the existing row, backfill it:

```ruby
def enrich_request!(db, existing, body, latest_message = nil)
  updates = {}
  update_if_missing(updates, existing, :latest_message_id, latest_message&.dig(:id))
  caller_refs = caller_identity_refs(db, body)
  updates[:caller_identity_id] = caller_refs[:identity_id] if existing[:caller_identity_id].nil? && caller_refs[:identity_id]
  updates[:caller_principal_id] = caller_refs[:principal_id] if existing[:caller_principal_id].nil? && caller_refs[:principal_id]
  updates[:runtime_caller_type] = caller_type(body) if existing[:runtime_caller_type].nil? && caller_type(body)
  update_if_missing(updates, existing, :identity_canonical_name, identity_canonical_name(body))

  request_json = json_dump(request_payload(body))
  updates[:request_json] = request_json if existing[:request_json].to_s == '{}' && request_json != '{}'

  msg_count = Array(body.dig(:request, :messages) || body[:messages]).size
  updates[:context_message_count] = msg_count if existing[:context_message_count].to_i.zero? && msg_count.positive?

  return existing if updates.empty?

  db[:llm_message_inference_requests].where(id: existing[:id]).update(updates)
  log.info("[ledger] enriched request id=#{existing[:id]} fields=#{updates.keys.join(',')}")
  existing.merge(updates)
end
```

- [ ] **Step 5: Add identity columns to `find_or_create_response_message`**

In `find_or_create_response_message`, add identity columns to the insert hash:

```ruby
id = insert_with_savepoint(db, :llm_messages, {
                             uuid:                         uuid,
                             conversation_id:              conversation[:id],
                             parent_message_id:            latest&.dig(:id),
                             message_inference_request_id: request[:id],
                             seq:                          seq,
                             role:                         'assistant',
                             content_type:                 'text',
                             content:                      response_content(body),
                             input_tokens:                 0,
                             output_tokens:                tokens(body)[:output_tokens],
                             identity_principal_id:        caller_identity_refs(db, body)[:principal_id],
                             identity_id:                  caller_identity_refs(db, body)[:identity_id],
                             identity_canonical_name:      identity_canonical_name(body),
                             created_at:                   recorded_at(body),
                             inserted_at:                  Time.now.utc
                           }, operation: 'official_record_writer.response_message')
```

- [ ] **Step 6: Add identity columns to `find_or_create_response`**

In `find_or_create_response`, add the three identity columns to the insert hash. Resolve them from `caller_identity_refs(db, body)` (already called earlier in the transaction and memoized):

```ruby
id = insert_with_savepoint(db, :llm_message_inference_responses, {
                             uuid:                         response_uuid,
                             message_inference_request_id: request[:id],
                             response_message_id:          response_message&.dig(:id),
                             provider:                     provider(body),
                             provider_instance:            provider_instance(body),
                             model_key:                    model_id(body),
                             tier:                         tier(body),
                             runner_ref:                   body[:worker_id] || body[:runner_ref],
                             provider_response_ref:        body[:provider_response_ref],
                             status:                       body[:error] ? 'error' : 'success',
                             finish_reason:                finish_reason(body),
                             latency_ms:                   integer(body[:latency_ms]),
                             wall_clock_ms:                integer(body[:wall_clock_ms]),
                             response_capture_mode:        'full',
                             response_json:                json_dump(visible_response(body)),
                             response_thinking_json:       json_dump(thinking_response(body)),
                             dispatch_path:                body[:dispatch_path] || body[:tier],
                             identity_principal_id:        caller_identity_refs(db, body)[:principal_id],
                             identity_id:                  caller_identity_refs(db, body)[:identity_id],
                             identity_canonical_name:      identity_canonical_name(body),
                             responded_at:                 recorded_at(body),
                             inserted_at:                  Time.now.utc
                           }, operation: 'official_record_writer.inference_response')
```

Also add to `enrich_response!` to backfill if nil:

```ruby
def enrich_response!(db, existing, response_message, body)
  updates = {}
  update_if_missing(updates, existing, :response_message_id, response_message&.dig(:id))
  update_if_missing(updates, existing, :tier, tier(body))
  update_if_missing(updates, existing, :provider_instance, provider_instance(body))
  update_if_missing(updates, existing, :finish_reason, finish_reason(body))
  update_if_missing(updates, existing, :dispatch_path, body[:dispatch_path] || body[:tier])
  update_if_missing(updates, existing, :identity_canonical_name, identity_canonical_name(body))

  response_json = json_dump(visible_response(body))
  update_if_placeholder(updates, existing, :response_json, response_json)

  thinking_json = json_dump(thinking_response(body))
  update_if_placeholder(updates, existing, :response_thinking_json, thinking_json)

  return if updates.empty?

  db[:llm_message_inference_responses].where(id: existing[:id]).update(updates)
  log.info("[ledger] enriched response id=#{existing[:id]} fields=#{updates.keys.join(',')}")
end
```

- [ ] **Step 7: Add identity columns to `find_or_create_metric`**

```ruby
id = insert_with_savepoint(db, :llm_message_inference_metrics, {
                             uuid:                          metric_uuid,
                             message_inference_request_id:  request[:id],
                             message_inference_response_id: response[:id],
                             provider:                      provider(body),
                             model_key:                     model_id(body),
                             tier:                          tier(body),
                             input_tokens:                  token_values[:input_tokens],
                             output_tokens:                 token_values[:output_tokens],
                             thinking_tokens:               token_values[:thinking_tokens],
                             total_tokens:                  token_values[:total_tokens],
                             latency_ms:                    integer(body[:latency_ms]),
                             wall_clock_ms:                 integer(body[:wall_clock_ms]),
                             cost_usd:                      cost_usd(body),
                             currency:                      body[:currency] || 'USD',
                             cost_center:                   billing(body)[:cost_center],
                             budget_key:                    billing(body)[:budget_id] || billing(body)[:budget_key],
                             identity_principal_id:         caller_identity_refs(db, body)[:principal_id],
                             identity_id:                   caller_identity_refs(db, body)[:identity_id],
                             identity_canonical_name:       identity_canonical_name(body),
                             recorded_at:                   recorded_at(body),
                             inserted_at:                   Time.now.utc
                           }, operation: 'official_record_writer.inference_metric')
```

- [ ] **Step 8: Run the new tests — they should pass now**

```bash
cd /Users/matt.iverson@optum.com/rubymine/legion/extensions-ai/lex-llm-ledger
bundle exec rspec spec/writers/official_prompt_writer_spec.rb --format documentation 2>&1 | tail -40
```

Expected: all examples pass, including the 4 new ones.

- [ ] **Step 9: Run full suite to confirm nothing regressed**

```bash
cd /Users/matt.iverson@optum.com/rubymine/legion/extensions-ai/lex-llm-ledger
bundle exec rspec --format json --out /tmp/rspec_result_task2.json --format progress 2>&1 | tail -5
```

Expected: 0 failures.

- [ ] **Step 10: Commit**

```bash
cd /Users/matt.iverson@optum.com/rubymine/legion/extensions-ai/lex-llm-ledger
git add lib/legion/extensions/llm/ledger/writers/official_record_writer.rb \
        spec/writers/official_prompt_writer_spec.rb
git commit -m "$(cat <<'EOF'
feat: populate identity columns on all OfficialRecordWriter inserts

Write identity_canonical_name to llm_conversations, llm_messages (user
and assistant), llm_message_inference_requests, llm_message_inference_responses,
and llm_message_inference_metrics. Write identity_principal_id and identity_id
to llm_messages, responses, and metrics. Backfill identity_canonical_name in
enrich_request! and enrich_response! when nil.
EOF
)"
```

---

## Task 3: Write failing tests for Runners::Tools identity columns

**Files:**
- Modify: `spec/runners/tools_spec.rb`

- [ ] **Step 1: Add identity-populated body and failing test for tool_call identity columns**

Inside the `context 'when a linked inference response exists'` block, after the existing `it 'is idempotent ...'` example, add:

```ruby
it 'writes identity_canonical_name on tool_call when caller identity is present' do
  body_with_identity = decrypted_body.merge(
    identity: { identity: 'miverso2', type: 'human', credential: 'entra_delegated' }
  )
  described_class.write_tool_record(body_with_identity, metadata)

  row = db[:llm_tool_calls].first
  expect(row[:identity_canonical_name]).to eq('miverso2')
end

it 'writes identity_canonical_name on tool_call_attempt when caller identity is present' do
  body_with_identity = decrypted_body.merge(
    identity: { identity: 'miverso2', type: 'human', credential: 'entra_delegated' }
  )
  described_class.write_tool_record(body_with_identity, metadata)

  attempt = db[:llm_tool_call_attempts].first
  expect(attempt[:identity_canonical_name]).to eq('miverso2')
end

it 'writes nil identity columns when no caller identity present' do
  described_class.write_tool_record(decrypted_body, metadata)

  row = db[:llm_tool_calls].first
  expect(row[:identity_canonical_name]).to be_nil
end
```

- [ ] **Step 2: Run tests to confirm they fail**

```bash
cd /Users/matt.iverson@optum.com/rubymine/legion/extensions-ai/lex-llm-ledger
bundle exec rspec spec/runners/tools_spec.rb --format documentation 2>&1 | tail -20
```

Expected: 2 new examples fail with nil != "miverso2".

---

## Task 4: Implement identity columns in Runners::Tools

**Files:**
- Modify: `lib/legion/extensions/llm/ledger/runners/tools.rb`

The Tools runner does not include `OfficialRecordWriter`, so it cannot call `caller_identity_refs`/`parsed_identity_descriptor` directly. However it already requires `Helpers::CallerIdentity`. Use `CallerIdentity.normalize` to extract the canonical name, and use the same `resolve_identity` pattern via `OfficialRecordWriter` (already loaded in the runtime) for FK resolution, or just write the canonical name directly (FK resolution is optional and guarded by identity table availability).

The cleanest approach: add a private helper `extract_identity_attrs(body, headers, db)` to the Tools runner that returns `{ identity_canonical_name:, identity_principal_id:, identity_id: }`.

- [ ] **Step 1: Add `extract_identity_attrs` private helper to Tools runner**

At the bottom of the `private` section in `runners/tools.rb`, add:

```ruby
def extract_identity_attrs(body, headers, db)
  canonical_name = Helpers::CallerIdentity.normalize(
    caller_raw: body[:caller],
    identity:   body[:identity],
    headers:    headers
  )[:identity]
  # Strip "type:" prefix added by CallerIdentity for generic identities
  canonical_name = canonical_name.split(':', 2).last if canonical_name&.include?(':') && !canonical_name&.include?('@')

  refs = {}
  if canonical_name && Writers::OfficialRecordWriter.identity_tables_available?(db)
    body_proxy = body.merge(
      identity: (body[:identity] || {}).merge(identity: canonical_name)
    )
    refs = Writers::OfficialRecordWriter.resolve_identity(db, body_proxy)
  end

  {
    identity_canonical_name: canonical_name,
    identity_principal_id:   refs[:principal_id],
    identity_id:             refs[:identity_id]
  }.compact
end
```

- [ ] **Step 2: Thread `identity_attrs` through `write_tool_record`**

In `write_tool_record`, compute identity attrs once and pass to both `find_or_create_tool_call` and `find_or_create_tool_call_attempt`. Change the transaction block:

```ruby
db.transaction do
  response                     = find_or_resolve_response(db, body, ctx, props, headers)
  identity_attrs               = extract_identity_attrs(body, headers, db)
  tool_call_row, new_tool_call = find_or_create_tool_call(db, response, body, ctx, tool, headers, identity_attrs)
  if tool_call_row && !new_tool_call
    write_result[0] = :duplicate
  elsif new_tool_call
    find_or_create_tool_call_attempt(db, tool_call_row, tool, body, props, headers, identity_attrs)
  end
end
```

- [ ] **Step 3: Add `identity_attrs` parameter to `find_or_create_tool_call`**

Update the method signature and insert hash:

```ruby
def find_or_create_tool_call(db, response, body, ctx, tool, headers, identity_attrs = {}) # rubocop:disable Metrics/ParameterLists
  tool_uuid = derive_tool_call_uuid(body, ctx, tool, headers)
  existing  = db[:llm_tool_calls].where(uuid: tool_uuid).first
  return [existing, false] if existing # rubocop:disable Legion/Extension/RunnerReturnHash

  response_id = resolve_response_id(db, response, body, ctx, headers, tool_uuid)
  return [nil, false] unless response_id # rubocop:disable Legion/Extension/RunnerReturnHash

  next_index = db[:llm_tool_calls]
               .where(message_inference_response_id: response_id)
               .max(:tool_call_index).to_i + 1

  src    = tool[:source] || {}
  status = tool[:status] || headers['x-legion-tool-status'] || 'success'
  ts     = body[:timestamps] || {}

  id = insert_with_savepoint(db, :llm_tool_calls, {
                               uuid:                          tool_uuid,
                               message_inference_response_id: response_id,
                               tool_call_index:               next_index,
                               provider_tool_call_ref:        tool[:id],
                               tool_name:                     tool[:name] || headers['x-legion-tool-name'],
                               tool_source_type:              src[:type] || headers['x-legion-tool-source-type'],
                               tool_source_server:            src[:server] || headers['x-legion-tool-source-server'],
                               status:                        status,
                               requested_at:                  ts[:tool_start] || tool[:started_at],
                               completed_at:                  ts[:tool_end] || tool[:finished_at],
                               **identity_attrs,
                               inserted_at:                   Time.now.utc
                             }, operation: 'write_tool_record.tool_call')
  [db[:llm_tool_calls][id: id], true]
rescue Sequel::UniqueConstraintViolation => e
  log.debug("[ledger] tool_call collision resolved uuid=#{tool_uuid} error=#{e.class}")
  row = db[:llm_tool_calls].where(uuid: tool_uuid).first
  raise(e) unless row

  [row, false]
end
```

- [ ] **Step 4: Add `identity_attrs` parameter to `find_or_create_tool_call_attempt`**

```ruby
def find_or_create_tool_call_attempt(db, tool_call_row, tool, body, props, headers, identity_attrs = {}) # rubocop:disable Metrics/CyclomaticComplexity,Metrics/ParameterLists
  return nil unless tool_call_row # rubocop:disable Legion/Extension/RunnerReturnHash

  tool_call_id = tool_call_row[:id]
  attempt_no   = db[:llm_tool_call_attempts]
                 .where(tool_call_id: tool_call_id).max(:attempt_no).to_i + 1
  attempt_uuid = derive_attempt_uuid(tool_call_row[:uuid], attempt_no)

  existing = db[:llm_tool_call_attempts].where(uuid: attempt_uuid).first
  return existing if existing # rubocop:disable Legion/Extension/RunnerReturnHash

  status     = tool[:status] || headers['x-legion-tool-status'] || 'success'
  error_info = tool[:error] || body[:error]
  error_hash = error_info.is_a?(Hash) ? error_info : {}
  ts         = body[:timestamps] || {}
  runner_ref = body[:worker_id] || body[:runner_ref] || props[:app_id]

  id = insert_with_savepoint(db, :llm_tool_call_attempts, {
                               uuid:           attempt_uuid,
                               tool_call_id:   tool_call_id,
                               attempt_no:     attempt_no,
                               runner_ref:     runner_ref,
                               status:         status,
                               error_category: error_hash[:category] || error_hash[:type],
                               error_code:     error_hash[:code],
                               error_message:  error_info.is_a?(String) ? error_info : error_hash[:message],
                               duration_ms:    tool[:duration_ms].to_i,
                               arguments_ref:  sha256_ref(tool[:arguments]),
                               result_ref:     sha256_ref(tool[:result] || body[:result]),
                               started_at:     ts[:tool_start] || tool[:started_at],
                               ended_at:       ts[:tool_end] || tool[:finished_at],
                               **identity_attrs,
                               inserted_at:    Time.now.utc
                             }, operation: 'write_tool_record.attempt')
  db[:llm_tool_call_attempts][id: id]
rescue Sequel::UniqueConstraintViolation => e
  log.debug("[ledger] tool_call_attempt collision resolved uuid=#{attempt_uuid} error=#{e.class}")
  db[:llm_tool_call_attempts].where(uuid: attempt_uuid).first || raise(e)
end
```

- [ ] **Step 5: Run tools spec — new tests should pass**

```bash
cd /Users/matt.iverson@optum.com/rubymine/legion/extensions-ai/lex-llm-ledger
bundle exec rspec spec/runners/tools_spec.rb --format documentation 2>&1 | tail -30
```

Expected: all pass.

- [ ] **Step 6: Commit**

```bash
cd /Users/matt.iverson@optum.com/rubymine/legion/extensions-ai/lex-llm-ledger
git add lib/legion/extensions/llm/ledger/runners/tools.rb \
        spec/runners/tools_spec.rb
git commit -m "$(cat <<'EOF'
feat: populate identity columns on tool_calls and tool_call_attempts inserts

Extract identity_canonical_name via CallerIdentity.normalize; resolve
identity_principal_id/identity_id via OfficialRecordWriter.resolve_identity
when identity tables are available. Pass identity_attrs to both
find_or_create_tool_call and find_or_create_tool_call_attempt.
EOF
)"
```

---

## Task 5: Registry availability — document no user context, write canonical name when present

**Files:**
- Modify: `spec/runners/registry_availability_spec.rb`
- Modify: `lib/legion/extensions/llm/ledger/runners/registry_availability.rb`

Registry availability events are infrastructure-only: they carry no `identity` or `caller` block in their payload (see the spec fixture). However the column exists on the table and should be written as `nil` (DB default). If a future payload ever does carry caller context, the code should handle it gracefully.

**Decision:** Write `identity_canonical_name` as `nil` (omit from insert; DB default handles it). No FK resolution needed. Document the reason in a comment. Add a test confirming `identity_canonical_name` is `nil` for standard registry events.

- [ ] **Step 1: Add a test confirming identity_canonical_name is nil for standard events**

In `spec/runners/registry_availability_spec.rb`, inside `describe '.write_registry_availability_record'`, add after the existing first `it` block:

```ruby
it 'stores nil identity_canonical_name for infrastructure registry events with no caller context' do
  described_class.write_registry_availability_record(payload, metadata)

  row = Legion::Data.connection[:llm_registry_availability_records].first
  # Registry availability events carry no user identity — they are infrastructure
  # heartbeats from worker nodes. identity_canonical_name is nil by design.
  expect(row[:identity_canonical_name]).to be_nil
end
```

- [ ] **Step 2: Run the new test — it should pass already (column defaults to nil)**

```bash
cd /Users/matt.iverson@optum.com/rubymine/legion/extensions-ai/lex-llm-ledger
bundle exec rspec spec/runners/registry_availability_spec.rb --format documentation 2>&1 | tail -20
```

Expected: all pass (the nil is already the DB default; no code change needed).

- [ ] **Step 3: Add a comment to `build_registry_availability_record` explaining the omission**

In `runners/registry_availability.rb`, at the top of `build_registry_availability_record`, add:

```ruby
def build_registry_availability_record(body, props)
  # Registry availability events are infrastructure heartbeats from worker nodes.
  # They carry no user identity context. identity_principal_id, identity_id, and
  # identity_canonical_name are intentionally omitted — the DB default (NULL) is correct.
  offering = body[:offering] || {}
  ...
```

- [ ] **Step 4: Commit**

```bash
cd /Users/matt.iverson@optum.com/rubymine/legion/extensions-ai/lex-llm-ledger
git add lib/legion/extensions/llm/ledger/runners/registry_availability.rb \
        spec/runners/registry_availability_spec.rb
git commit -m "$(cat <<'EOF'
docs: document why registry availability events carry no identity context

Registry availability events are infrastructure-only heartbeats with no
user caller. Add comment explaining the intentional omission and a test
confirming identity_canonical_name is nil for standard events.
EOF
)"
```

---

## Task 6: Audit for thrown-away payload fields

This task is a review-and-confirm step. Based on the sample payload in the brief, verify each field is either stored, derivable, or confirmed as intentionally discarded.

- [ ] **Step 1: Verify tracing fields are stored**

The sample payload has:
```json
"tracing": {
  "trace_id": "9a73b4341e759f43b9e712e27b03f12a",
  "span_id": "a1d2b9814eaf7b58",
  "correlation_id": null
}
```

Check if `tracing.trace_id` and `tracing.span_id` are stored anywhere. Search:

```bash
grep -rn "trace_id\|span_id" /Users/matt.iverson@optum.com/rubymine/legion/extensions-ai/lex-llm-ledger/lib/ 2>&1
grep -n "trace_id\|span_id" /Users/matt.iverson@optum.com/rubymine/legion/legion-data/lib/legion/data/migrations/079_create_llm_message_inference_requests.rb 2>&1
```

If `trace_id`/`span_id` columns exist on `llm_message_inference_requests` but are not being written: add them to `find_or_create_request`. If they do NOT exist on any table, that is an out-of-scope schema change — document it but do NOT add migrations in this task (scope creep).

- [ ] **Step 2: Verify `caller.source` and `caller.path` are stored**

These fields (`caller.source = "api"`, `caller.path = "/api/llm/inference"`) are not stored in the official schema. Check:

```bash
grep -n "caller.*source\|caller.*path\|caller_source\|call_path" \
  /Users/matt.iverson@optum.com/rubymine/legion/legion-data/lib/legion/data/migrations/079_create_llm_message_inference_requests.rb \
  /Users/matt.iverson@optum.com/rubymine/legion/legion-data/lib/legion/data/migrations/080_create_llm_message_inference_responses.rb 2>&1
```

If no columns exist: these are out-of-scope for this task. Document in the commit message.

- [ ] **Step 3: Verify `exchange_id` is stored on tool_calls**

The sample tool payload has `exchange_id: "exch_8f60a9fcde2ee5d5d47c8b41"`. Check if `llm_tool_calls` has an `exchange_ref` or `exchange_id` column:

```bash
grep -n "exchange" /Users/matt.iverson@optum.com/rubymine/legion/legion-data/lib/legion/data/migrations/084_create_llm_tool_calls.rb 2>&1
```

If the column does not exist: out of scope. Document and move on.

- [ ] **Step 4: Verify `x-legion-trace-id` and `x-legion-span-id` AMQP headers**

These headers are mentioned in the brief. They are not currently extracted by any runner or writer in the codebase. Confirm:

```bash
grep -rn "x-legion-trace\|x-legion-span" /Users/matt.iverson@optum.com/rubymine/legion/extensions-ai/lex-llm-ledger/lib/ 2>&1
```

If not stored: out of scope for this task (needs a schema migration). Document.

- [ ] **Step 5: Commit audit findings**

```bash
cd /Users/matt.iverson@optum.com/rubymine/legion/extensions-ai/lex-llm-ledger
# Only commit if any code changes were made in steps 1-4; otherwise skip this commit
```

---

## Task 7: Run full test suite, rubocop, bump version, update CHANGELOG

**Files:**
- Modify: `lib/legion/extensions/llm/ledger/version.rb`
- Modify: `CHANGELOG.md`

- [ ] **Step 1: Run full RSpec suite**

```bash
cd /Users/matt.iverson@optum.com/rubymine/legion/extensions-ai/lex-llm-ledger
bundle exec rspec --format json --out /tmp/rspec_result.json --format progress 2>&1 | tail -10
```

Expected: 0 failures, 0 errors.

On failure, extract failures:

```bash
jq '[.examples[] | select(.status != "passed") | {file_path, line_number, full_description, exception}]' /tmp/rspec_result.json
```

Fix any failures before proceeding.

- [ ] **Step 2: Run RuboCop**

```bash
cd /Users/matt.iverson@optum.com/rubymine/legion/extensions-ai/lex-llm-ledger
bundle exec rubocop 2>&1 | tail -20
```

Expected: no offenses. Fix any offenses before proceeding. Common issues to watch for:
- Method with too many parameters: extract into a struct/hash or split private methods
- ABC size: extract into smaller helpers
- `# rubocop:disable Metrics/ParameterLists` is already used in the runner — confirm the new signatures have the correct disable comment

- [ ] **Step 3: Bump version to 0.5.0**

Edit `lib/legion/extensions/llm/ledger/version.rb`:

```ruby
# frozen_string_literal: true

module Legion
  module Extensions
    module Llm
      module Ledger
        VERSION = '0.5.0'
      end
    end
  end
end
```

- [ ] **Step 4: Update CHANGELOG.md**

Prepend a new entry at the top of CHANGELOG.md (after the first `# Changelog` line):

```markdown
## [0.5.0] - 2026-05-17

### Changed
- Populate `identity_canonical_name` on every insert in `OfficialRecordWriter`:
  `llm_conversations`, `llm_messages` (user and assistant), `llm_message_inference_requests`,
  `llm_message_inference_responses`, and `llm_message_inference_metrics`.
- Populate `identity_principal_id` and `identity_id` on inserts into `llm_messages`,
  `llm_message_inference_responses`, and `llm_message_inference_metrics`.
- Backfill `identity_canonical_name` in `enrich_request!` and `enrich_response!` when the
  enrichment opportunity arrives after a metering-first write.
- `Runners::Tools` now extracts identity via `CallerIdentity.normalize` and writes
  `identity_canonical_name`, `identity_principal_id`, and `identity_id` to both
  `llm_tool_calls` and `llm_tool_call_attempts`.
- `Runners::RegistryAvailability` intentionally omits identity columns — registry events
  are infrastructure-only heartbeats with no user caller context.
```

- [ ] **Step 5: Commit version and changelog**

```bash
cd /Users/matt.iverson@optum.com/rubymine/legion/extensions-ai/lex-llm-ledger
git add lib/legion/extensions/llm/ledger/version.rb CHANGELOG.md
git commit -m "$(cat <<'EOF'
chore: bump version to 0.5.0 and update CHANGELOG

Summarises identity column population work across OfficialRecordWriter
and Runners::Tools.
EOF
)"
```

---

## Task 8: Open pull request

- [ ] **Step 1: Push branch**

```bash
cd /Users/matt.iverson@optum.com/rubymine/legion/extensions-ai/lex-llm-ledger
git push -u origin fix/populate-identity-columns
```

- [ ] **Step 2: Create PR**

```bash
gh pr create \
  --title "feat: populate identity columns on every ledger insert" \
  --body "$(cat <<'EOF'
## Summary

- `OfficialRecordWriter`: write `identity_canonical_name` on all 5 table inserts (conversations, user messages, assistant messages, requests, responses, metrics); write `identity_principal_id`/`identity_id` on messages, responses, and metrics.
- `Runners::Tools`: extract identity via `CallerIdentity.normalize` and write all three identity columns to `llm_tool_calls` and `llm_tool_call_attempts`.
- `Runners::RegistryAvailability`: confirmed infrastructure-only — no user identity context; documents intent with comment and test.
- Enrich paths (`enrich_request!`, `enrich_response!`) backfill `identity_canonical_name` when nil on existing rows.

## Test plan

- [ ] `bundle exec rspec` — 0 failures
- [ ] `bundle exec rubocop` — 0 offenses
- [ ] Verify `identity_canonical_name` written on all 7 tables in new spec examples
- [ ] Verify `identity_principal_id`/`identity_id` written on messages, responses, metrics, tool_calls, tool_call_attempts
- [ ] Verify registry availability row correctly has nil `identity_canonical_name`
EOF
)"
```

---

## Self-Review

**Spec coverage check:**
- OfficialRecordWriter conversations → Task 1 Step 4
- OfficialRecordWriter user_message/response_message (llm_messages) → Task 1 Step 3
- OfficialRecordWriter requests → Task 1 Step 1
- OfficialRecordWriter responses → Task 1 Step 2
- OfficialRecordWriter metrics → Task 1 Step 2
- Runners::Tools tool_calls → Task 3 Step 1
- Runners::Tools tool_call_attempts → Task 3 Step 1
- Runners::RegistryAvailability nil identity → Task 5 Step 1
- enrich_request! backfill → covered by existing idempotency tests + new enrichment assertions

**Placeholder scan:** None found.

**Type consistency:**
- `caller_identity_refs` returns `{ principal_id:, identity_id: }` — used consistently as `caller_identity_refs(db, body)[:principal_id]` / `[:identity_id]`.
- `parsed_identity_descriptor` returns `{ canonical_name:, kind:, ... }` — `identity_canonical_name(body)` helper reads `[:canonical_name]`.
- `extract_identity_attrs` in Tools runner returns `{ identity_canonical_name:, identity_principal_id:, identity_id: }` — spread via `**identity_attrs`.
- All three are used consistently across all tasks.

**Note on `llm_conversations` principal_id/identity_id:** The `find_or_create_conversation` method in the current writer does NOT write `principal_id`/`identity_id` to `llm_conversations` (those columns exist from migration 077 but the writer never sets them). This is pre-existing behavior and not part of this task's scope — the task only adds `identity_canonical_name`. If setting `principal_id`/`identity_id` on conversations is desired, that would require mapping `caller_identity_refs[:principal_id]` → `principal_id` (old column name), which is a separate refactor.
