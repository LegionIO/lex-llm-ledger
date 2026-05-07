# frozen_string_literal: true

require_relative 'official_record_writer'

module Legion
  module Extensions
    module Llm
      module Ledger
        module Writers
          module OfficialPromptWriter
            module_function

            def write(payload)
              OfficialRecordWriter.write_prompt(payload)
            end
          end
        end
      end
    end
  end
end
