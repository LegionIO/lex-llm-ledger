# frozen_string_literal: true

Sequel.migration do # rubocop:disable Metrics/BlockLength
  change do
    create_table(:metering_records) do
      primary_key :id

      String   :message_id,       null: false, unique: true
      String   :correlation_id,   null: false
      String   :conversation_id,  null: false
      String   :message_id_ctx,   null: false
      String   :parent_message_id
      Integer  :message_seq
      String   :request_id, null: false
      String   :exchange_id
      String   :request_type,     null: false
      String   :tier,             null: false
      String   :provider,         null: false
      String   :model_id,         null: false
      String   :node_id,          null: false
      String   :worker_id
      String   :agent_id
      String   :task_id
      Integer  :input_tokens,     null: false, default: 0
      Integer  :output_tokens,    null: false, default: 0
      Integer  :thinking_tokens,  null: false, default: 0
      Integer  :total_tokens,     null: false, default: 0
      Integer  :latency_ms,       null: false, default: 0
      Integer  :wall_clock_ms,    null: false, default: 0
      Float    :cost_usd,         null: false, default: 0.0
      String   :routing_reason
      String   :cost_center
      String   :budget_id
      String   :recorded_at,      null: false
      DateTime :inserted_at,      null: false, default: Sequel::CURRENT_TIMESTAMP

      index [:conversation_id]
      index [:request_id]
      index [:message_id_ctx]
      index [:correlation_id]
      index %i[provider model_id]
      index [:node_id]
      index [:worker_id]
      index [:recorded_at]
      index %i[cost_center recorded_at]
    end
  end
end
