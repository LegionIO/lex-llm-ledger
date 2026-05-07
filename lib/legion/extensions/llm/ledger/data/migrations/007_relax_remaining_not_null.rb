# frozen_string_literal: true

Sequel.migration do
  up do
    alter_table(:llm_metering_records) do
      set_column_allow_null :model_id
    end

    alter_table(:llm_registry_availability_records) do
      set_column_allow_null :event_type
      set_column_allow_null :occurred_at
      set_column_allow_null :offering_json
      set_column_allow_null :runtime_json
      set_column_allow_null :capacity_json
      set_column_allow_null :health_json
      set_column_allow_null :lane_json
      set_column_allow_null :metadata_json
    end
  end

  down do
    alter_table(:llm_metering_records) do
      set_column_not_null :model_id
    end

    alter_table(:llm_registry_availability_records) do
      set_column_not_null :event_type
      set_column_not_null :occurred_at
      set_column_not_null :offering_json
      set_column_not_null :runtime_json
      set_column_not_null :capacity_json
      set_column_not_null :health_json
      set_column_not_null :lane_json
      set_column_not_null :metadata_json
    end
  end
end
