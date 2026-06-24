# frozen_string_literal: true

require 'legion/extensions/actors/subscription'

module Legion
  module Extensions
    module Llm
      module Ledger
        module Actor
          class Escalations < Legion::Extensions::Actors::Subscription
            prefetch 1

            def runner_class = Legion::Extensions::Llm::Ledger::Runners::Escalations

            def runner_function = 'insert'

            def use_runner?
              false
            end

            def queue
              Legion::Extensions::Llm::Ledger::Transport::Queues::AuditEscalations
            end
          end
        end
      end
    end
  end
end
