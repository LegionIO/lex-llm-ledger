# Phase 3 — Consumer Identity Population Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Update write paths in lex-llm-ledger, lex-apollo, and lex-knowledge to populate the new standard identity FK columns (`identity_principal_id`, `identity_id`, `identity_canonical_name`) on every row they write. Use `Legion::Data::Helpers::IdentityResolver` (shipped in Phase 1) to resolve canonical names to integer PKs. Also update `access_scope` population in lex-apollo at ingest time (default `global`; `private` for channel-sourced entries tagged with source channels designated private).

**Architecture:** All three repos already have identity string information flowing in via AMQP headers or payload. The work is purely additive: read the new integer PK headers when present, fall back to `IdentityResolver.resolve(db, ...)` when they are absent, and populate the three new columns on every `INSERT`. No existing columns are touched. No schema changes — those landed in Phase 1.

**Prerequisites:** Phase 1 (legion-data migrations 100–124 merged) and Phase 2 (transport integer headers) must be complete.

**Tech Stack:** Ruby 3.4+, Sequel (raw dataset writes), RSpec, RuboCop.

---

## Repos Covered

| Repo | What Changes |
|------|-------------|
| `lex-llm-ledger` | `OfficialRecordWriter` — all `insert_with_savepoint` calls for LLM tables get identity columns; `OfficialMeteringWriter` and `OfficialPromptWriter` same |
| `lex-apollo` | `Runners::Knowledge#create_candidate_entry` and `handle_ingest` get identity fields; `access_scope` added to `create_candidate_entry` |
| `lex-knowledge` | `Runners::Ingest#ingest_to_apollo` passes identity context fields |

---

## File Map

### lex-llm-ledger

| Action | File |
|--------|------|
| Modify | `lib/legion/extensions/llm/ledger/writers/official_record_writer.rb` |
| Modify | `lib/legion/extensions/llm/ledger/writers/official_metering_writer.rb` |
| Modify | `lib/legion/extensions/llm/ledger/writers/official_prompt_writer.rb` |
| Modify | `lib/legion/extensions/llm/ledger/helpers/caller_identity.rb` |
| Test   | `spec/legion/extensions/llm/ledger/writers/official_record_writer_spec.rb` |

### lex-apollo

| Action | File |
|--------|------|
| Modify | `lib/legion/extensions/apollo/runners/knowledge.rb` |
| Modify | `lib/legion/extensions/apollo/helpers/data_models.rb` |
| Test   | `spec/legion/extensions/apollo/runners/knowledge_spec.rb` |

### lex-knowledge

| Action | File |
|--------|------|
| Modify | `lib/legion/extensions/knowledge/runners/ingest.rb` |
| Test   | `spec/legion/extensions/knowledge/runners/ingest_spec.rb` |

---

## lex-llm-ledger Changes

### Task 1: Extend CallerIdentity.normalize to read integer PK headers

**Files:**
- Modify: `lib/legion/extensions/llm/ledger/helpers/caller_identity.rb`

- [ ] **Step 1: Write the failing test**

```ruby
# spec/legion/extensions/llm/ledger/helpers/caller_identity_spec.rb
require 'spec_helper'

RSpec.describe Legion::Extensions::Llm::Ledger::Helpers::CallerIdentity do
  describe '.normalize' do
    it 'extracts integer pk headers when present' do
      headers = {
        'x-legion-identity-canonical-name' => 'alice',
        'x-legion-identity-kind'           => 'human',
        'x-legion-identity-principal-id'   => '42',
        'x-legion-identity-db-id'          => '99'
      }
      result = described_class.normalize(headers: headers)
      expect(result[:db_principal_id]).to eq(42)
      expect(result[:db_identity_id]).to eq(99)
    end

    it 'returns nil db PKs when headers absent' do
      result = described_class.normalize(headers: {})
      expect(result[:db_principal_id]).to be_nil
      expect(result[:db_identity_id]).to be_nil
    end

    it 'returns nil db PKs when header value is not a valid integer string' do
      headers = { 'x-legion-identity-principal-id' => 'not-a-number' }
      result = described_class.normalize(headers: headers)
      expect(result[:db_principal_id]).to be_nil
    end
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd extensions-ai/lex-llm-ledger && bundle exec rspec spec/legion/extensions/llm/ledger/helpers/caller_identity_spec.rb -e "integer pk headers" --format documentation
```

- [ ] **Step 3: Update CallerIdentity.normalize**

In `lib/legion/extensions/llm/ledger/helpers/caller_identity.rb`, update the `normalize` method's return hash to include the integer PK fields:

```ruby
def normalize(caller_raw: nil, identity: nil, headers: {})
  caller_hash = caller_raw.is_a?(Hash) ? caller_raw : {}
  caller = hash_value(caller_hash, :requested_by)
  caller = caller_hash unless caller.is_a?(Hash)
  identity_hash = identity.is_a?(Hash) ? identity : {}
  extension = hash_value(caller_hash, :extension)
  type = first_present(
    hash_value(identity_hash, :type),
    header_value(headers, 'x-legion-caller-type'),
    hash_value(caller, :type),
    extension && 'extension'
  )

  raw_identity = first_present(
    hash_value(identity_hash, :id),
    hash_value(identity_hash, :canonical_name),
    hash_value(identity_hash, :identity),
    hash_value(identity_hash, :username),
    header_value(headers, 'x-legion-identity-canonical-name'),
    header_value(headers, 'x-legion-identity'),
    header_value(headers, 'x-legion-caller-identity'),
    hash_value(caller, :id),
    hash_value(caller, :canonical_name),
    hash_value(caller, :identity),
    hash_value(caller, :username),
    extension && "extension:#{extension}"
  )

  db_principal_id = integer_header(headers, 'x-legion-identity-principal-id')
  db_identity_id  = integer_header(headers, 'x-legion-identity-db-id')

  {
    identity:        normalize_identity_value(raw_identity, type),
    type:            type,
    db_principal_id: db_principal_id,
    db_identity_id:  db_identity_id
  }.compact
end
```

Add the private helper `integer_header` at the bottom of the module:

```ruby
def integer_header(headers, key)
  val = header_value(headers, key)
  return nil unless present?(val) && val.to_s.match?(/\A\d+\z/)

  val.to_i
end
```

- [ ] **Step 4: Run test**

```bash
bundle exec rspec spec/legion/extensions/llm/ledger/helpers/caller_identity_spec.rb --format documentation
```

- [ ] **Step 5: Commit**

```bash
git add lib/legion/extensions/llm/ledger/helpers/caller_identity.rb spec/legion/extensions/llm/ledger/helpers/caller_identity_spec.rb
git commit -m "CallerIdentity: extract integer DB PK headers from AMQP envelope"
```

---

### Task 2: Populate identity columns in OfficialRecordWriter

**Files:**
- Modify: `lib/legion/extensions/llm/ledger/writers/official_record_writer.rb`

The writer already calls `caller_identity_refs(db, body)` which resolves `{ principal_id:, identity_id: }`. We need to:
1. Also extract `identity_canonical_name` from the body/headers
2. Pass all three fields to every `INSERT` that touches a table with the new columns

- [ ] **Step 1: Write the failing test**

```ruby
# spec/legion/extensions/llm/ledger/writers/official_record_writer_spec.rb
require 'spec_helper'

RSpec.describe Legion::Extensions::Llm::Ledger::Writers::OfficialRecordWriter do
  describe '#find_or_create_user_message' do
    let(:db)           { double('db') }
    let(:conversation) { { id: 1 } }
    let(:body) do
      {
        'x-legion-identity-canonical-name': 'alice',
        'x-legion-identity-principal-id':   '42',
        'x-legion-identity-db-id':          '99',
        caller_identity:                    'alice'
      }
    end

    before do
      allow(db).to receive(:table_exists?).and_return(true)
      allow(db).to receive(:[]).and_return(double('dataset', where: double(first: nil), insert: 1, fetch: []))
      allow(Legion::Data).to receive(:connection).and_return(db)
    end

    it 'includes identity_principal_id in message insert payload' do
      messages_ds = instance_double(Sequel::Dataset)
      allow(db).to receive(:[]).with(:llm_messages).and_return(messages_ds)
      expect(messages_ds).to receive(:where).and_return(messages_ds)
      expect(messages_ds).to receive(:first).and_return(nil)
      expect(messages_ds).to receive(:insert) do |payload|
        expect(payload[:identity_principal_id]).to eq(42)
        expect(payload[:identity_canonical_name]).to eq('alice')
        1
      end
      allow(messages_ds).to receive(:[]).and_return({ id: 1 })
      described_class.write_prompt(body)
    end
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

```bash
bundle exec rspec spec/legion/extensions/llm/ledger/writers/official_record_writer_spec.rb -e "identity_principal_id" --format documentation
```

- [ ] **Step 3: Add identity column population to OfficialRecordWriter**

The writer already has `caller_identity_refs(db, body)` returning `{ principal_id:, identity_id: }`. Add a new private method `caller_identity_canonical_name(body)` that extracts the canonical name, and add a method `identity_row_attrs(db, body)` that bundles all three columns:

Add after the existing `caller_identity_refs` method (around line 362):

```ruby
def identity_row_attrs(db, body)
  refs = caller_identity_refs(db, body)
  canonical = body[:identity_canonical_name] ||
              body.dig(:identity, :canonical_name) ||
              parsed_identity_descriptor(body)[:canonical_name]
  {
    identity_principal_id:  refs[:principal_id],
    identity_id:            refs[:identity_id],
    identity_canonical_name: canonical&.to_s&.slice(0, 255)
  }.compact
end
```

Then, for every `insert_with_savepoint` call that writes to a table that received identity columns in Phase 1 migrations, merge `identity_row_attrs(db, body)`:

Tables that need it: `llm_messages`, `llm_message_inference_requests`, `llm_message_inference_responses`, `llm_message_inference_metrics`, `llm_policy_evaluations`, `llm_route_attempts`, `llm_security_events`, `llm_tool_calls`, `llm_tool_call_attempts`, `llm_registry_events`.

For each insert, add `**identity_row_attrs(db, body)` to the hash. Example for `find_or_create_user_message`:

```ruby
id = insert_with_savepoint(db, :llm_messages, {
                               uuid:            uuid,
                               conversation_id: conversation[:id],
                               seq:             seq,
                               role:            'user',
                               content_type:    'text',
                               content:         request_content(body),
                               input_tokens:    tokens(body)[:input_tokens],
                               output_tokens:   0,
                               created_at:      recorded_at(body),
                               inserted_at:     Time.now.utc,
                               **identity_row_attrs(db, body)
                             }, operation: 'official_record_writer.user_message')
```

Apply the same pattern to `find_or_create_response_message`, `find_or_create_request`, `find_or_create_response`, `find_or_create_metric`, and any other inserts for those tables. Search for `insert_with_savepoint(db, :llm_` to find all call sites.

- [ ] **Step 4: Run test**

```bash
bundle exec rspec spec/legion/extensions/llm/ledger/writers/official_record_writer_spec.rb --format documentation
```

- [ ] **Step 5: Run full suite**

```bash
bundle exec rspec --format progress && bundle exec rubocop -A
```

- [ ] **Step 6: Commit**

```bash
git add lib/legion/extensions/llm/ledger/writers/official_record_writer.rb spec/legion/extensions/llm/ledger/writers/official_record_writer_spec.rb
git commit -m "OfficialRecordWriter: populate identity FK columns on all LLM table inserts"
```

---

### Task 3: Update OfficialMeteringWriter and OfficialPromptWriter

**Files:**
- Modify: `lib/legion/extensions/llm/ledger/writers/official_metering_writer.rb`
- Modify: `lib/legion/extensions/llm/ledger/writers/official_prompt_writer.rb`

Both writers do their own DB inserts for metering/prompt tables. Apply the same `identity_row_attrs` pattern if they write to tables in the Phase 1 migrations list.

- [ ] **Step 1: Read both files to identify insert sites**

```bash
grep -n "insert_with_savepoint\|db\[:" lib/legion/extensions/llm/ledger/writers/official_metering_writer.rb | head -20
grep -n "insert_with_savepoint\|db\[:" lib/legion/extensions/llm/ledger/writers/official_prompt_writer.rb | head -20
```

- [ ] **Step 2: Write the failing tests**

For each writer, add one test asserting that `identity_principal_id` appears in insert payloads for affected tables.

- [ ] **Step 3: Add `identity_row_attrs` calls to affected inserts**

Require `identity_row_attrs` to be accessible (extract to a shared module or duplicate the method). Both writers `require` official_record_writer — if `identity_row_attrs` is defined as `module_function` there, both can call `OfficialRecordWriter.identity_row_attrs(db, body)`. Refactor accordingly if needed.

- [ ] **Step 4: Run tests + full suite**

```bash
bundle exec rspec --format progress && bundle exec rubocop -A
```

- [ ] **Step 5: Commit**

```bash
git add lib/legion/extensions/llm/ledger/writers/official_{metering,prompt}_writer.rb
git commit -m "OfficialMeteringWriter/OfficialPromptWriter: populate identity FK columns"
```

---

## lex-apollo Changes

### Task 4: Populate identity columns at ingest time + access_scope

**Files:**
- Modify: `lib/legion/extensions/apollo/runners/knowledge.rb`

The `handle_ingest` method already accepts `submitted_by:` and `submitted_from:`. We need to add three new keyword params: `identity_principal_id:`, `identity_id:`, `identity_canonical_name:`, and `access_scope:` (default `'global'`). Pass them to `create_candidate_entry`.

- [ ] **Step 1: Write the failing test**

```ruby
# spec/legion/extensions/apollo/runners/knowledge_spec.rb
RSpec.describe Legion::Extensions::Apollo::Runners::Knowledge do
  let(:host) { Object.new.extend(described_class) }

  describe '#create_candidate_entry' do
    it 'includes identity_principal_id in the entry row' do
      allow(Legion::Extensions::Apollo::Helpers::DataModels).to receive(:apollo_entry) do
        ds = double('dataset')
        allow(ds).to receive(:create) do |attrs|
          expect(attrs[:identity_principal_id]).to eq(42)
          expect(attrs[:access_scope]).to eq('global')
          double('entry', id: 1)
        end
        ds
      end

      host.send(:create_candidate_entry,
                content: 'test', content_type: 'observation', context: {},
                metadata: { tags: [], domain: 'general', source_agent: 'test',
                            source_provider: 'local', source_channel: nil,
                            submitted_by: nil, submitted_from: nil },
                content_hash: nil, embedding: nil,
                identity_principal_id: 42, identity_id: 1,
                identity_canonical_name: 'alice', access_scope: 'global')
    end
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd extensions/lex-apollo && bundle exec rspec spec/legion/extensions/apollo/runners/knowledge_spec.rb -e "identity_principal_id" --format documentation
```

- [ ] **Step 3: Update handle_ingest and create_candidate_entry**

In `lib/legion/extensions/apollo/runners/knowledge.rb`:

1. Add new keyword params to `handle_ingest` signature:

```ruby
def handle_ingest(content: nil, content_type: nil, tags: [], source_agent: 'unknown',
                  source_provider: nil, source_channel: nil, knowledge_domain: nil,
                  submitted_by: nil, submitted_from: nil, content_hash: nil, context: {},
                  identity_principal_id: nil, identity_id: nil, identity_canonical_name: nil,
                  access_scope: 'global', skip: false, **)
```

2. Update the `create_candidate_entry` call in `handle_ingest` to pass the new fields:

```ruby
existing_id = create_candidate_entry(
  content: content, content_type: content_type_sym, context: context,
  metadata: metadata, content_hash: hash, embedding: embedding,
  identity_principal_id: identity_principal_id,
  identity_id: identity_id,
  identity_canonical_name: identity_canonical_name,
  access_scope: access_scope
)
```

3. Update `create_candidate_entry` to accept and use them:

```ruby
def create_candidate_entry(content:, content_type:, context:, metadata:, content_hash:, embedding:,
                           identity_principal_id: nil, identity_id: nil,
                           identity_canonical_name: nil, access_scope: 'global')
  new_entry = Helpers::DataModels.apollo_entry.create(
    content:                content,
    content_type:           content_type,
    confidence:             Helpers::Confidence.initial_confidence,
    source_agent:           metadata[:source_agent],
    source_provider:        metadata[:source_provider],
    source_channel:         metadata[:source_channel],
    source_context:         json_dump(context.is_a?(Hash) ? context : {}),
    tags:                   Sequel.pg_array(metadata[:tags]),
    status:                 'candidate',
    knowledge_domain:       metadata[:domain],
    submitted_by:           metadata[:submitted_by],
    submitted_from:         metadata[:submitted_from],
    content_hash:           content_hash,
    embedding:              embedding ? Sequel.lit("'[#{embedding.join(',')}]'::vector") : nil,
    identity_principal_id:  identity_principal_id,
    identity_id:            identity_id,
    identity_canonical_name: identity_canonical_name,
    access_scope:           access_scope || 'global'
  )
  # ...rest unchanged
end
```

4. Also update `handle_ingest` to pass `access_scope` through `ingest_metadata` → the corroboration access_log create to record it (access_log doesn't need access_scope, just entries).

- [ ] **Step 4: Run test + full suite**

```bash
bundle exec rspec spec/legion/extensions/apollo/runners/knowledge_spec.rb --format documentation
bundle exec rspec --format progress && bundle exec rubocop -A
```

- [ ] **Step 5: Commit**

```bash
git add lib/legion/extensions/apollo/runners/knowledge.rb spec/legion/extensions/apollo/runners/knowledge_spec.rb
git commit -m "lex-apollo: populate identity FK columns and access_scope at ingest time"
```

---

## lex-knowledge Changes

### Task 5: Pass identity context fields through lex-knowledge ingest

**Files:**
- Modify: `lib/legion/extensions/knowledge/runners/ingest.rb`

lex-knowledge calls `Legion::Extensions::Apollo::Runners::Knowledge.handle_ingest(**payload)`. We need to add identity fields to that payload.

Document corpus ingest has no per-user identity (it's a system-level operation), so we populate:
- `identity_canonical_name:` = the booting agent's canonical name (from `Legion::Identity::Process.canonical_name` if available)
- `identity_principal_id:` = `Legion::Identity::Process.db_principal_id` if available  
- `identity_id:` = `Legion::Identity::Process.db_identity_id` if available
- `access_scope:` = `'global'` (document corpus is always global)

- [ ] **Step 1: Write the failing test**

```ruby
# spec/legion/extensions/knowledge/runners/ingest_spec.rb
RSpec.describe Legion::Extensions::Knowledge::Runners::Ingest do
  describe '.ingest_to_apollo' do
    it 'passes access_scope global to handle_ingest' do
      chunk = {
        content: 'test content', content_hash: 'abc123', source_file: 'test.md',
        heading: 'Test', section_path: ['Test'], chunk_index: 0, token_count: 10
      }
      expect(Legion::Extensions::Apollo::Runners::Knowledge).to receive(:handle_ingest) do |**args|
        expect(args[:access_scope]).to eq('global')
        { success: true, entry_id: 1 }
      end
      described_class.send(:ingest_to_apollo, chunk, nil)
    end

    it 'passes identity_canonical_name when Identity::Process is available' do
      chunk = {
        content: 'test content', content_hash: 'abc123', source_file: 'test.md',
        heading: 'Test', section_path: ['Test'], chunk_index: 0, token_count: 10
      }
      allow(Legion::Identity::Process).to receive(:canonical_name).and_return('system-agent')
      allow(Legion::Identity::Process).to receive(:db_principal_id).and_return(nil)
      allow(Legion::Identity::Process).to receive(:db_identity_id).and_return(nil)

      expect(Legion::Extensions::Apollo::Runners::Knowledge).to receive(:handle_ingest) do |**args|
        expect(args[:identity_canonical_name]).to eq('system-agent')
        { success: true, entry_id: 1 }
      end
      described_class.send(:ingest_to_apollo, chunk, nil)
    end
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd extensions/lex-knowledge && bundle exec rspec spec/legion/extensions/knowledge/runners/ingest_spec.rb -e "access_scope global" --format documentation
```

- [ ] **Step 3: Update ingest_to_apollo**

In `lib/legion/extensions/knowledge/runners/ingest.rb`, update the `ingest_to_apollo` private method:

```ruby
def ingest_to_apollo(chunk, embedding)
  return unless defined?(Legion::Extensions::Apollo)

  context = {
    source_file:  chunk[:source_file],
    heading:      chunk[:heading],
    section_path: chunk[:section_path],
    chunk_index:  chunk[:chunk_index],
    token_count:  chunk[:token_count]
  }
  payload = {
    content:                 chunk[:content],
    content_type:            'document_chunk',
    content_hash:            chunk[:content_hash],
    tags:                    [chunk[:source_file], chunk[:heading], 'document_chunk'].compact.uniq,
    context:                 context,
    metadata:                context,
    access_scope:            'global',
    identity_canonical_name: identity_process_canonical_name,
    identity_principal_id:   identity_process_principal_id,
    identity_id:             identity_process_identity_id
  }
  payload[:embedding] = embedding if embedding
  payload.compact!

  Legion::Extensions::Apollo::Runners::Knowledge.handle_ingest(**payload)
end
private_class_method :ingest_to_apollo

def identity_process_canonical_name
  return nil unless defined?(Legion::Identity::Process) && Legion::Identity::Process.respond_to?(:canonical_name)

  Legion::Identity::Process.canonical_name
rescue StandardError
  nil
end
private_class_method :identity_process_canonical_name

def identity_process_principal_id
  return nil unless defined?(Legion::Identity::Process) && Legion::Identity::Process.respond_to?(:db_principal_id)

  Legion::Identity::Process.db_principal_id
rescue StandardError
  nil
end
private_class_method :identity_process_principal_id

def identity_process_identity_id
  return nil unless defined?(Legion::Identity::Process) && Legion::Identity::Process.respond_to?(:db_identity_id)

  Legion::Identity::Process.db_identity_id
rescue StandardError
  nil
end
private_class_method :identity_process_identity_id
```

- [ ] **Step 4: Run test + full suite**

```bash
bundle exec rspec spec/legion/extensions/knowledge/runners/ingest_spec.rb --format documentation
bundle exec rspec --format progress && bundle exec rubocop -A
```

- [ ] **Step 5: Commit**

```bash
git add lib/legion/extensions/knowledge/runners/ingest.rb spec/legion/extensions/knowledge/runners/ingest_spec.rb
git commit -m "lex-knowledge: pass access_scope=global and system identity fields through ingest_to_apollo"
```

---

### Task 6: Final verification across all three repos

- [ ] **Step 1: Run full lex-llm-ledger suite**

```bash
cd extensions-ai/lex-llm-ledger && bundle exec rspec --format progress && bundle exec rubocop
```

- [ ] **Step 2: Run full lex-apollo suite**

```bash
cd extensions/lex-apollo && bundle exec rspec --format progress && bundle exec rubocop
```

- [ ] **Step 3: Run full lex-knowledge suite**

```bash
cd extensions/lex-knowledge && bundle exec rspec --format progress && bundle exec rubocop
```

All three must report zero failures and zero rubocop offenses before opening PRs.
