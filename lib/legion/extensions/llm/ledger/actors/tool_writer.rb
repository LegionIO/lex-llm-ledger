# frozen_string_literal: true

require 'legion/extensions/actors/subscription'
require_relative '../helpers/subscription_actor'

module Legion
  module Extensions
    module Llm
      module Ledger
        module Actor
          class ToolWriter < Legion::Extensions::Actors::Subscription
            include Helpers::SubscriptionActor

            def runner_class = Legion::Extensions::Llm::Ledger::Runners::Tools

            def runner_function
              'write_tool_record'
            end

            def use_runner?
              false
            end

            def queue
              Legion::Extensions::Llm::Ledger::Transport::Queues::AuditTools
            end
          end
        end
      end
    end
  end
end
