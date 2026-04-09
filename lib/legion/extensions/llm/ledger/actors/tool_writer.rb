# frozen_string_literal: true

require 'legion/extensions/actors/subscription'

module Legion
  module Extensions
    module LLM
      module Ledger
        module Actor
          class ToolWriter < Legion::Extensions::Actors::Subscription
            def runner_class = Legion::Extensions::LLM::Ledger::Runners::Tools

            def runner_function
              'write_tool_record'
            end

            def use_runner?
              false
            end
          end
        end
      end
    end
  end
end
