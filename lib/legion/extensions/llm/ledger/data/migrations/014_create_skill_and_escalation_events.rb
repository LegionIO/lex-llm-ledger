# frozen_string_literal: true

Sequel.migration do # rubocop:disable Metrics/BlockLength
  up do # rubocop:disable Metrics/BlockLength
    create_table(:llm_skill_events) do
      primary_key :id

      String   :uuid, null: false, unique: true, size: 36
      Integer  :conversation_id
      String   :request_ref
      String   :skill_name, null: false
      String   :skill_version
      String   :trigger
      String   :status, null: false, default: 'completed'
      Integer  :duration_ms, default: 0
      String   :identity_canonical_name
      Integer  :identity_principal_id
      Integer  :identity_id
      Integer  :schema_version, null: false, default: 14
      DateTime :recorded_at, null: false
      DateTime :inserted_at, null: false, default: Sequel::CURRENT_TIMESTAMP

      index [:conversation_id]
      index [:request_ref]
      index [:skill_name]
      index [:identity_canonical_name]
      index [:recorded_at]
      index [:inserted_at]
    end

    create_table(:llm_escalation_events) do
      primary_key :id

      String   :uuid, null: false, unique: true, size: 36
      Integer  :conversation_id
      String   :request_ref
      String   :from_provider
      String   :from_instance
      String   :from_model
      String   :to_provider
      String   :to_instance
      String   :to_model
      String   :reason
      String   :error_category
      Integer  :attempt_no, default: 1
      Integer  :latency_ms, default: 0
      String   :identity_canonical_name
      Integer  :identity_principal_id
      Integer  :identity_id
      Integer  :schema_version, null: false, default: 14
      DateTime :recorded_at, null: false
      DateTime :inserted_at, null: false, default: Sequel::CURRENT_TIMESTAMP

      index [:conversation_id]
      index [:request_ref]
      index [:from_provider]
      index [:to_provider]
      index [:identity_canonical_name]
      index [:recorded_at]
      index [:inserted_at]
    end
  end

  down do
    drop_table(:llm_escalation_events)
    drop_table(:llm_skill_events)
  end
end
