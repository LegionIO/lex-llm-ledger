# frozen_string_literal: true

module Legion
  module Extensions
    module Llm
      module Ledger
        module Transport
          module Exchanges
            class Audit < ::Legion::Transport::Exchange
              def exchange_name
                'llm.audit'
              end

              def default_type
                'topic'
              end
            end
          end
        end
      end
    end
  end
end
