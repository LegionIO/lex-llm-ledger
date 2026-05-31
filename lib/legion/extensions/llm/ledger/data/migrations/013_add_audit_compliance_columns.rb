# frozen_string_literal: true

Sequel.migration do # rubocop:disable Metrics/BlockLength
  up do
    alter_table(:llm_message_inference_requests) do
      add_column :parent_request_id, Integer, null: true
      add_column :schema_version, Integer, null: false, default: 13
      add_index :parent_request_id
    end

    alter_table(:llm_message_inference_responses) do
      add_column :schema_version, Integer, null: false, default: 13
    end

    alter_table(:llm_message_inference_metrics) do
      add_column :schema_version, Integer, null: false, default: 13
    end

    alter_table(:llm_conversations) do
      add_column :pii_types_json, String, text: true
      add_column :jurisdictions_json, String, text: true
      add_column :schema_version, Integer, null: false, default: 13
    end

    alter_table(:llm_tool_calls) do
      add_column :schema_version, Integer, null: false, default: 13
    end

    alter_table(:llm_tool_call_attempts) do
      add_column :schema_version, Integer, null: false, default: 13
    end
  end

  down do
    alter_table(:llm_message_inference_requests) do
      drop_index :parent_request_id
      drop_column :parent_request_id
      drop_column :schema_version
    end

    alter_table(:llm_message_inference_responses) do
      drop_column :schema_version
    end

    alter_table(:llm_message_inference_metrics) do
      drop_column :schema_version
    end

    alter_table(:llm_conversations) do
      drop_column :pii_types_json
      drop_column :jurisdictions_json
      drop_column :schema_version
    end

    alter_table(:llm_tool_calls) do
      drop_column :schema_version
    end

    alter_table(:llm_tool_call_attempts) do
      drop_column :schema_version
    end
  end
end
