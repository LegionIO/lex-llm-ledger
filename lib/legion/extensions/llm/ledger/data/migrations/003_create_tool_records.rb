# frozen_string_literal: true

Sequel.migration do # rubocop:disable Metrics/BlockLength
  change do
    create_table(:tool_records) do
      primary_key :id

      String    :message_id,          null: false, unique: true
      String    :correlation_id,      null: false
      String    :conversation_id,     null: false
      String    :message_id_ctx,      null: false
      String    :parent_message_id
      Integer   :message_seq
      String    :request_id, null: false
      String    :exchange_id
      String    :tool_call_id,        null: false
      String    :tool_name,           null: false
      String    :tool_source_type
      String    :tool_source_server
      String    :tool_status,         null: false
      Integer   :tool_duration_ms,    default: 0
      String    :arguments_json,      text: true
      String    :result_json,         text: true
      String    :error_json,          text: true
      String    :caller_identity
      String    :agent_id
      String    :classification_level
      TrueClass :contains_phi,        null: false, default: false
      String    :retention_policy,    null: false, default: 'default'
      DateTime  :expires_at
      String    :tool_start_at
      String    :tool_end_at
      DateTime  :inserted_at, null: false, default: Sequel::CURRENT_TIMESTAMP

      index [:conversation_id]
      index [:request_id]
      index [:message_id_ctx]
      index [:correlation_id]
      index [:tool_name]
      index %i[tool_source_server tool_name]
      index [:tool_status]
      index [:contains_phi]
      index [:expires_at]
      index [:inserted_at]
    end
  end
end
