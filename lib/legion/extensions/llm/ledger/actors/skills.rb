# frozen_string_literal: true

require 'legion/extensions/actors/subscription'
require_relative '../helpers/subscription_actor'

module Legion
  module Extensions
    module Llm
      module Ledger
        module Actor
          class Skills < Legion::Extensions::Actors::Subscription
            include Helpers::SubscriptionActor

            prefetch 1

            def runner_class = Legion::Extensions::Llm::Ledger::Runners::Skills

            def runner_function = 'insert'

            def use_runner?
              false
            end

            def queue
              Legion::Extensions::Llm::Ledger::Transport::Queues::AuditSkills
            end
          end
        end
      end
    end
  end
end
