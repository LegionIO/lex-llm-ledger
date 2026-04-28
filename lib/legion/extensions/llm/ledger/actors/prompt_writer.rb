# frozen_string_literal: true

require 'legion/extensions/actors/subscription'
require_relative '../helpers/subscription_message'

module Legion
  module Extensions
    module Llm
      module Ledger
        module Actor
          class PromptWriter < Legion::Extensions::Actors::Subscription
            def runner_class = Legion::Extensions::Llm::Ledger::Runners::Prompts

            def runner_function
              'write_prompt_record'
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
