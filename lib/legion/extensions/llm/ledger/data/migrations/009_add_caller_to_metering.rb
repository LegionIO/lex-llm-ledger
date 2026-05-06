# frozen_string_literal: true

Sequel.migration do
  up do
    alter_table(:llm_metering_records) do
      add_column :caller_identity, String
      add_column :caller_type, String
    end
  end

  down do
    alter_table(:llm_metering_records) do
      drop_column :caller_identity
      drop_column :caller_type
    end
  end
end
