# frozen_string_literal: true

module Legion
  module Extensions
    module Llm
      module Ledger
        module Actor
          class Reconciliation < Legion::Extensions::Actors::Every
            def runner_class
              'Legion::Extensions::Llm::Ledger::Runners::Reconciliation'
            end

            def runner_function
              'link_orphaned_tool_calls'
            end

            def time
              120
            end

            def run
              Legion::Extensions::Llm::Ledger::Runners::Reconciliation.link_orphaned_tool_calls
              Legion::Extensions::Llm::Ledger::Runners::Reconciliation.link_metering_messages
            rescue StandardError => e
              handle_exception(e, level: :warn, handled: true, operation: 'reconciliation')
            end

            def run_now?
              false
            end

            def use_runner?
              false
            end

            def check_subtask?
              false
            end

            def generate_task?
              false
            end
          end
        end
      end
    end
  end
end
