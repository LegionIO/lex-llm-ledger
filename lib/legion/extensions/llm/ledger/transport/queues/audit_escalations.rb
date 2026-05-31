# frozen_string_literal: true

module Legion
  module Extensions
    module Llm
      module Ledger
        module Transport
          module Queues
            class AuditEscalations < Legion::Transport::Queue
              def queue_name
                'llm.audit.escalations'
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
