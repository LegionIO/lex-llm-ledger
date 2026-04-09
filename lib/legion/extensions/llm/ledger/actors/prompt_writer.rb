# frozen_string_literal: true

require 'legion/extensions/actors/subscription'

module Legion
  module Extensions
    module LLM
      module Ledger
        module Actor
          class PromptWriter < Legion::Extensions::Actors::Subscription
            def runner_class = Legion::Extensions::LLM::Ledger::Runners::Prompts

            def runner_function
              'write_prompt_record'
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
