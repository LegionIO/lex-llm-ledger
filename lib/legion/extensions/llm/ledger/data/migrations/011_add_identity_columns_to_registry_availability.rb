# frozen_string_literal: true

Sequel.migration do
  up do
    alter_table(:llm_registry_availability_records) do
      add_column :access_scope,            String, size: 20, null: false, default: 'global'
      add_column :identity_principal_id,   Integer, null: true
      add_column :identity_id,             Integer, null: true
      add_column :identity_canonical_name, String, size: 255, null: true
    end

    alter_table(:llm_registry_availability_records) do
      add_index :identity_principal_id
      add_index :identity_id
      add_index :access_scope
    end
  end

  down do
    alter_table(:llm_registry_availability_records) do
      drop_index :identity_principal_id
      drop_index :identity_id
      drop_index :access_scope
      drop_column :access_scope
      drop_column :identity_principal_id
      drop_column :identity_id
      drop_column :identity_canonical_name
    end
  end
end
