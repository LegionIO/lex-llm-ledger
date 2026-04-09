# frozen_string_literal: true

require 'legion/extensions/transport'
require 'legion/llm/transport/exchanges/metering'
require 'legion/llm/transport/exchanges/audit'

module Legion
  module Extensions
    module Llm
      module Ledger
        module Transport
          extend Legion::Extensions::Transport

          def self.additional_e_to_q
            [
              {
                from:        Legion::LLM::Transport::Exchanges::Metering,
                to:          Legion::Extensions::Llm::Ledger::Transport::Queues::MeteringWrite,
                routing_key: 'metering.#'
              },
              {
                from:        Legion::LLM::Transport::Exchanges::Audit,
                to:          Legion::Extensions::Llm::Ledger::Transport::Queues::AuditPrompts,
                routing_key: 'audit.prompt.#'
              },
              {
                from:        Legion::LLM::Transport::Exchanges::Audit,
                to:          Legion::Extensions::Llm::Ledger::Transport::Queues::AuditTools,
                routing_key: 'audit.tool.#'
              }
            ]
          end
        end
      end
    end
  end
end
