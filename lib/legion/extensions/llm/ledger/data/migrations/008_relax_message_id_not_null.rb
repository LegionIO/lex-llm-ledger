# frozen_string_literal: true

Sequel.migration do
  up do
    %i[llm_metering_records llm_prompt_records llm_tool_records].each do |table|
      alter_table(table) do
        set_column_allow_null :message_id
      end
    end
  end

  down do
    %i[llm_metering_records llm_prompt_records llm_tool_records].each do |table|
      alter_table(table) do
        set_column_not_null :message_id
      end
    end
  end
end
