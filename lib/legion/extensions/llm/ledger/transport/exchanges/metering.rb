# frozen_string_literal: true

module Legion
  module Extensions
    module LLM
      module Ledger
        module Transport
          module Exchanges
            class Metering < Legion::Transport::Exchange
              def exchange_name
                'llm.metering'
              end

              def default_type
                'topic'
              end

              def passive?
                true
              end
            end
          end
        end
      end
    end
  end
end
