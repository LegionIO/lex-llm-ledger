# frozen_string_literal: true

Sequel.migration do
  up do
    rename_table :llm_metering_records,  :z_archive_llm_metering_records
    rename_table :llm_prompt_records,    :z_archive_llm_prompt_records
    rename_table :llm_tool_records,      :z_archive_llm_tool_records
  end

  down do
    rename_table :z_archive_llm_metering_records, :llm_metering_records
    rename_table :z_archive_llm_prompt_records,   :llm_prompt_records
    rename_table :z_archive_llm_tool_records,     :llm_tool_records
  end
end
