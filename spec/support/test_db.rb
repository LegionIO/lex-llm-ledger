# frozen_string_literal: true

require 'sequel'
require 'sequel/extensions/migration'

module TestDb
  # Tables that require the standardized identity columns.
  # legion-data migrations 103-114 add these, but may not be on disk yet.
  IDENTITY_TABLES = %i[
    llm_conversations
    llm_messages
    llm_message_inference_requests
    llm_message_inference_responses
    llm_message_inference_metrics
    llm_route_attempts
    llm_tool_calls
    llm_tool_call_attempts
    llm_conversation_compactions
    llm_policy_evaluations
    llm_security_events
  ].freeze

  module_function

  def setup
    db = Sequel.sqlite
    Sequel::Migrator.run(db, legion_data_migration_dir)
    ensure_identity_columns!(db)
    ensure_audit_columns!(db)
    ensure_context_accounting_columns!(db)
    migration_dir = File.expand_path('../../lib/legion/extensions/llm/ledger/data/migrations', __dir__)
    Sequel::Migrator.run(db, migration_dir, table: :schema_migrations_lex_llm_ledger)
    db
  end

  def legion_data_migration_dir
    configured = ENV.fetch('LEGION_DATA_PATH', nil)
    return File.join(configured, 'lib/legion/data/migrations') if configured && !configured.empty?

    local = File.expand_path('../../../../legion-data/lib/legion/data/migrations', __dir__)
    return local if File.directory?(local)

    spec = Gem.loaded_specs['legion-data']
    File.join(spec.full_gem_path, 'lib/legion/data/migrations')
  end

  # Add standardized identity columns to LLM tables when legion-data migrations
  # 103-114 are not yet available on disk (e.g. still on a branch).
  def ensure_identity_columns!(db)
    IDENTITY_TABLES.each do |table|
      next unless db.table_exists?(table)

      columns = db[table].columns
      db.alter_table(table) do
        add_column :access_scope, String, size: 20, null: false, default: 'global' unless columns.include?(:access_scope)
        add_column :identity_principal_id, Integer, null: true unless columns.include?(:identity_principal_id)
        add_column :identity_id, Integer, null: true unless columns.include?(:identity_id)
        add_column :identity_canonical_name, String, size: 255, null: true unless columns.include?(:identity_canonical_name)
      end
    end

    ensure_runtime_caller_columns!(db)
  end

  # Add runtime_caller_class and runtime_caller_client to llm_message_inference_requests
  # when legion-data migrations adding these columns are not yet on disk.
  def ensure_runtime_caller_columns!(db)
    table = :llm_message_inference_requests
    return unless db.table_exists?(table)

    columns = db[table].columns
    db.alter_table(table) do
      add_column :runtime_caller_class, String, size: 255, null: true unless columns.include?(:runtime_caller_class)
      add_column :runtime_caller_client, String, size: 255, null: true unless columns.include?(:runtime_caller_client)
    end
  end

  # Safety net: context accounting columns from migration 135 may not be on
  # disk if running against an older legion-data checkout.
  def ensure_context_accounting_columns!(db)
    table = :llm_message_inference_metrics
    return unless db.table_exists?(table)

    existing = db[table].columns
    context_cols = %i[
      request_message_estimated_tokens loaded_history_estimated_tokens
      curated_history_estimated_tokens curation_saved_estimated_tokens
      stripped_thinking_estimated_tokens archived_history_estimated_tokens
      archive_saved_estimated_tokens context_window_saved_estimated_tokens
      rag_injected_estimated_tokens system_prompt_estimated_tokens
      baseline_system_estimated_tokens tool_definition_estimated_tokens
      final_context_estimated_tokens loaded_history_message_count
      curated_history_message_count archived_history_message_count
      stripped_thinking_message_count context_window_message_count_before
      context_window_message_count_after rag_entry_count tool_definition_count
    ]

    db.alter_table(table) do
      context_cols.each do |col|
        add_column(col, Integer, null: false, default: 0) unless existing.include?(col)
      end
      add_column(:context_accounting_status, String, size: 64, null: false, default: 'missing') unless existing.include?(:context_accounting_status)
      add_column(:context_accounting_json, String, text: true) unless existing.include?(:context_accounting_json)
    end

    return if db.table_exists?(:llm_context_accounting_events)

    db.create_table(:llm_context_accounting_events) do
      primary_key :id
      String :uuid, size: 36, null: false, unique: true
      foreign_key :message_inference_request_id, :llm_message_inference_requests, null: false, on_delete: :cascade
      foreign_key :message_inference_response_id, :llm_message_inference_responses, null: true, on_delete: :set_null
      foreign_key :message_inference_metric_id, :llm_message_inference_metrics, null: true, on_delete: :set_null
      String :conversation_ref, size: 128
      String :request_ref, size: 128, null: false
      String :event_type, size: 64, null: false
      String :component, size: 64, null: false
      Integer :estimated_tokens_before, null: false, default: 0
      Integer :estimated_tokens_after, null: false, default: 0
      Integer :estimated_tokens_delta, null: false, default: 0
      Integer :message_count_before, null: false, default: 0
      Integer :message_count_after, null: false, default: 0
      String :metadata_json, text: true
      DateTime :recorded_at
      DateTime :inserted_at, null: false, default: Sequel::CURRENT_TIMESTAMP
    end
  end

  # Safety net: columns added by legion-data migrations 123-128 that may not
  # be on disk yet when the ledger runs against an older legion-data release.
  def ensure_audit_columns!(db)
    # llm_tool_calls (migration 123)
    ensure_columns(db, :llm_tool_calls,
                   %i[tool_arguments_json tool_result_json tool_category data_handling_classification
                      policy_decision requires_human_approval])

    # llm_tool_call_attempts (migration 124)
    ensure_columns(db, :llm_tool_call_attempts,
                   %i[attempt_input_json attempt_output_json error_details_json])

    # llm_escalation_events (migration 125)
    ensure_columns(db, :llm_escalation_events,
                   %i[history_json outcome total_attempts])

    # llm_message_inference_responses (migration 126)
    ensure_columns(db, :llm_message_inference_responses,
                   %i[route_attempts escalation_chain_ref])

    # llm_message_inference_requests (migration 127)
    ensure_columns(db, :llm_message_inference_requests,
                   %i[parent_request_id])
  end

  def ensure_columns(db, table, columns)
    return unless db.table_exists?(table)

    existing = db[table].columns
    db.alter_table(table) do
      columns.each do |col|
        add_column(col, String, text: true) unless existing.include?(col)
      end
    end
  end
end
