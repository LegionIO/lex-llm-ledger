# frozen_string_literal: true

module Legion
  module Extensions
    module Llm
      module Ledger
        module Actor
          class RetentionPurge < Legion::Extensions::Actors::Every
            def runner_class
              'Legion::Extensions::Llm::Ledger::Runners::RetentionPurge'
            end

            def runner_function
              'purge_expired'
            end

            def time
              3600
            end

            def run
              Runners::RetentionPurge.purge_expired
            rescue StandardError => e
              handle_exception(e, level: :warn, handled: true, operation: 'retention_purge')
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
