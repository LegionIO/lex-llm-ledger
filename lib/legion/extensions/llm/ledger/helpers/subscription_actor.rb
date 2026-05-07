# frozen_string_literal: true

require_relative 'subscription_message'

module Legion
  module Extensions
    module Llm
      module Ledger
        module Helpers
          module SubscriptionActor
            def process_message(message, metadata, delivery_info)
              SubscriptionMessage.decode_payload(message, metadata, delivery_info)
            rescue DecryptionFailed => e
              raise unrecoverable_message_error(e)
            end

            private

            def unrecoverable_message_error(error)
              if defined?(Legion::Extensions::Actors::UnrecoverableMessageError)
                Legion::Extensions::Actors::UnrecoverableMessageError.new(error.message)
              else
                error
              end
            end
          end
        end
      end
    end
  end
end
