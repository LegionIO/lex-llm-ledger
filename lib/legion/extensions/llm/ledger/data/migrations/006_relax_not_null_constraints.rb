# frozen_string_literal: true

Sequel.migration do # rubocop:disable Metrics/BlockLength
  up do
    alter_table(:llm_metering_records) do
      set_column_allow_null :request_type
      set_column_allow_null :recorded_at
    end

    alter_table(:llm_prompt_records) do
      set_column_allow_null :correlation_id
      set_column_allow_null :conversation_id
      set_column_allow_null :message_id_ctx
      set_column_allow_null :request_id
      set_column_allow_null :provider
      set_column_allow_null :model_id
      set_column_allow_null :request_json
      set_column_allow_null :response_json
      set_column_allow_null :recorded_at
    end

    alter_table(:llm_tool_records) do
      set_column_allow_null :correlation_id
      set_column_allow_null :conversation_id
      set_column_allow_null :message_id_ctx
      set_column_allow_null :request_id
      set_column_allow_null :tool_call_id
      set_column_allow_null :tool_name
      set_column_allow_null :tool_status
    end
  end

  down do
    alter_table(:llm_metering_records) do
      set_column_not_null :request_type
      set_column_not_null :recorded_at
    end

    alter_table(:llm_prompt_records) do
      set_column_not_null :correlation_id
      set_column_not_null :conversation_id
      set_column_not_null :message_id_ctx
      set_column_not_null :request_id
      set_column_not_null :provider
      set_column_not_null :model_id
      set_column_not_null :request_json
      set_column_not_null :response_json
      set_column_not_null :recorded_at
    end

    alter_table(:llm_tool_records) do
      set_column_not_null :correlation_id
      set_column_not_null :conversation_id
      set_column_not_null :message_id_ctx
      set_column_not_null :request_id
      set_column_not_null :tool_call_id
      set_column_not_null :tool_name
      set_column_not_null :tool_status
    end
  end
end
