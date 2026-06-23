# frozen_string_literal: true

require 'legion/extensions/actors/subscription'

module Legion
  module Extensions
    module Llm
      module Ledger
        module Actor
          class Prompts < Legion::Extensions::Actors::Subscription

            prefetch 1

            def runner_class = Legion::Extensions::Llm::Ledger::Runners::Prompts

            def runner_function
              'insert'
            end

            def use_runner?
              false
            end

            def queue
              Legion::Extensions::Llm::Ledger::Transport::Queues::AuditPrompts
            end
          end
        end
      end
    end
  end
end
