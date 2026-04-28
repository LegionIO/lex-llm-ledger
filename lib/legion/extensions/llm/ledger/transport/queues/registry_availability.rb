# frozen_string_literal: true

module Legion
  module Extensions
    module Llm
      module Ledger
        module Transport
          module Queues
            class RegistryAvailability < Legion::Transport::Queue
              def queue_name
                'llm.registry.availability'
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
