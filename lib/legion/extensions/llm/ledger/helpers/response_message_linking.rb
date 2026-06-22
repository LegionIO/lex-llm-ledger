# frozen_string_literal: true

require 'legion/logging'

module Legion
  module Extensions
    module Llm
      module Ledger
        module Helpers
          # Response message linking: backfill the FK from llm_messages
          # to llm_message_inference_responses after a response row is created.
          module ResponseMessageLinking
            extend Legion::Logging::Helper

            module_function

            def response_message_linking_link_response_message!(db, response_message, response)
              return unless response_message && response
              return if response_message[:message_inference_response_id] == response[:id]

              db[:llm_messages].where(id: response_message[:id]).update(message_inference_response_id: response[:id])
            end
          end
        end
      end
    end
  end
end
