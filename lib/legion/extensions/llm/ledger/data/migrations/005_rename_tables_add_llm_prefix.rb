# frozen_string_literal: true

Sequel.migration do
  up do
    rename_table :metering_records, :llm_metering_records
    rename_table :prompt_records, :llm_prompt_records
    rename_table :tool_records, :llm_tool_records
    rename_table :registry_availability_records, :llm_registry_availability_records

    alter_table(:llm_metering_records) do
      set_column_allow_null :correlation_id
      set_column_allow_null :conversation_id
      set_column_allow_null :message_id_ctx
      set_column_allow_null :request_id
      set_column_allow_null :tier
      set_column_allow_null :provider
      set_column_allow_null :node_id
    end
  end

  down do
    alter_table(:llm_metering_records) do
      set_column_not_null :correlation_id
      set_column_not_null :conversation_id
      set_column_not_null :message_id_ctx
      set_column_not_null :request_id
      set_column_not_null :tier
      set_column_not_null :provider
      set_column_not_null :node_id
    end

    rename_table :llm_metering_records, :metering_records
    rename_table :llm_prompt_records, :prompt_records
    rename_table :llm_tool_records, :tool_records
    rename_table :llm_registry_availability_records, :registry_availability_records
  end
end
