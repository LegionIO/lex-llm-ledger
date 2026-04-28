# frozen_string_literal: true

require 'legion/extensions/actors/subscription'
require_relative '../helpers/subscription_message'

module Legion
  module Extensions
    module Llm
      module Ledger
        module Actor
          class RegistryAvailabilityWriter < Legion::Extensions::Actors::Subscription
            def runner_class = Legion::Extensions::Llm::Ledger::Runners::RegistryAvailability

            def runner_function
              'write_registry_availability_record'
            end

            def use_runner?
              false
            end

            def process_message(message, metadata, delivery_info)
              Helpers::SubscriptionMessage.decode_payload(message, metadata, delivery_info)
            end
          end
        end
      end
    end
  end
end
