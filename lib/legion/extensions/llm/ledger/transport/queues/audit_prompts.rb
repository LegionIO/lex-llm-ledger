# frozen_string_literal: true

module Legion
  module Extensions
    module Llm
      module Ledger
        module Transport
          module Queues
            class AuditPrompts < Legion::Transport::Queue
              def queue_name
                'llm.audit.prompts'
              end

              def queue_options
                { durable: true }
              end
            end
          end
        end
      end
    end
  end
end
