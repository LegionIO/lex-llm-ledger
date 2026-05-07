# frozen_string_literal: true

require_relative 'official_record_writer'

module Legion
  module Extensions
    module Llm
      module Ledger
        module Writers
          module OfficialMeteringWriter
            module_function

            def write(payload)
              OfficialRecordWriter.write_metering(payload)
            end
          end
        end
      end
    end
  end
end
