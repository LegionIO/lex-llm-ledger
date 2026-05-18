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
end
