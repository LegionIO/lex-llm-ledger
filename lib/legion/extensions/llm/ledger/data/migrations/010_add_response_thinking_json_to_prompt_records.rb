# frozen_string_literal: true

Sequel.migration do
  up do
    alter_table(:llm_prompt_records) do
      add_column :response_thinking_json, String, text: true
    end
  end

  down do
    alter_table(:llm_prompt_records) do
      drop_column :response_thinking_json
    end
  end
end
