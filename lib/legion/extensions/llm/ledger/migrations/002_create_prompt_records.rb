# frozen_string_literal: true

Sequel.migration do # rubocop:disable Metrics/BlockLength
  change do # rubocop:disable Metrics/BlockLength
    create_table(:prompt_records) do # rubocop:disable Metrics/BlockLength
      primary_key :id

      String    :message_id,         null: false, unique: true
      String    :correlation_id,     null: false
      String    :conversation_id,    null: false
      String    :message_id_ctx,     null: false
      String    :parent_message_id
      Integer   :message_seq
      String    :request_id, null: false
      String    :exchange_id
      String    :response_message_id
      String    :provider,           null: false
      String    :model_id,           null: false
      String    :tier
      String    :request_type
      String    :request_json,       null: false, text: true
      String    :response_json,      null: false, text: true
      Integer   :input_tokens,       default: 0
      Integer   :output_tokens,      default: 0
      Integer   :total_tokens,       default: 0
      Float     :cost_usd,           default: 0.0
      String    :caller_identity
      String    :caller_type
      String    :agent_id
      String    :task_id
      String    :classification_level
      TrueClass :contains_phi,       null: false, default: false
      TrueClass :contains_pii,       null: false, default: false
      String    :jurisdictions
      Integer   :quality_score
      String    :quality_band
      String    :retention_policy, null: false, default: 'default'
      DateTime  :expires_at
      String    :recorded_at,        null: false
      DateTime  :inserted_at,        null: false, default: Sequel::CURRENT_TIMESTAMP

      index [:conversation_id]
      index [:request_id]
      index [:message_id_ctx]
      index [:correlation_id]
      index [:response_message_id]
      index [:caller_identity]
      index %i[provider model_id]
      index [:contains_phi]
      index [:expires_at]
      index [:inserted_at]
    end
  end
end
