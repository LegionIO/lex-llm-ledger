# frozen_string_literal: true

Sequel.migration do # rubocop:disable Metrics/BlockLength
  change do
    create_table(:registry_availability_records) do
      primary_key :id

      String   :event_id, null: false, unique: true
      String   :message_id
      String   :correlation_id
      String   :routing_key
      String   :event_type,        null: false
      String   :occurred_at,       null: false
      String   :offering_id
      String   :provider_family
      String   :provider_instance
      String   :instance_id
      String   :model_family
      String   :model_id
      String   :canonical_model
      String   :provider_model
      String   :usage_type
      String   :transport
      String   :lane_key
      String   :worker_id
      String   :node_id
      String   :offering_json,     null: false, text: true
      String   :runtime_json,      null: false, text: true
      String   :capacity_json,     null: false, text: true
      String   :health_json,       null: false, text: true
      String   :lane_json,         null: false, text: true
      String   :metadata_json,     null: false, text: true
      DateTime :inserted_at,       null: false, default: Sequel::CURRENT_TIMESTAMP

      index [:event_type]
      index [:occurred_at]
      index [:offering_id]
      index [:provider_family]
      index [:provider_instance]
      index %i[provider_family model_id]
      index [:lane_key]
      index [:worker_id]
      index [:node_id]
      index [:inserted_at]
    end
  end
end
