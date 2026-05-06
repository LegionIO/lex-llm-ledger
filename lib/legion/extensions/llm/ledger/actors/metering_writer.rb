# frozen_string_literal: true

require 'legion/extensions/actors/subscription'
require_relative '../helpers/subscription_message'

module Legion
  module Extensions
    module Llm
      module Ledger
        module Actor
          class MeteringWriter < Legion::Extensions::Actors::Subscription
            def runner_class = Legion::Extensions::Llm::Ledger::Runners::Metering

            def runner_function
              'write_metering_record'
            end

            def use_runner?
              false
            end

            def queue
              Legion::Extensions::Llm::Ledger::Transport::Queues::MeteringWrite
            end
          end
        end
      end
    end
  end
end
