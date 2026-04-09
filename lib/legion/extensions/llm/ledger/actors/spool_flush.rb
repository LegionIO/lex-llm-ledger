# frozen_string_literal: true

module Legion
  module Extensions
    module Llm
      module Ledger
        module Actor
          class SpoolFlush < Legion::Extensions::Actors::Every # rubocop:disable Legion/Extension/EveryActorRequiresTime
            def runner_class
              'Legion::Extensions::Llm::Ledger::Runners::Metering'
            end

            def runner_function
              'spool_flush'
            end

            def time
              60
            end

            def run
              return unless defined?(Legion::LLM::Metering) &&
                            Legion::LLM::Metering.respond_to?(:flush_spool)

              Legion::LLM::Metering.flush_spool
            rescue StandardError => e
              Legion::Logging.warn("[lex-llm-ledger] SpoolFlush error: #{e.message}") # rubocop:disable Legion/HelperMigration/DirectLogging
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
