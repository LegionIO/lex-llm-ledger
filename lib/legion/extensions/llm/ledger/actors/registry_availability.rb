# frozen_string_literal: true

require 'legion/extensions/actors/subscription'

module Legion
  module Extensions
    module Llm
      module Ledger
        module Actor
          class RegistryAvailability < Legion::Extensions::Actors::Subscription

            prefetch 4

            def runner_class = Legion::Extensions::Llm::Ledger::Runners::RegistryAvailability

            def runner_function = 'insert'

            def use_runner?
              false
            end

            def queue
              Legion::Extensions::Llm::Ledger::Transport::Queues::RegistryAvailability
            end
          end
        end
      end
    end
  end
end
