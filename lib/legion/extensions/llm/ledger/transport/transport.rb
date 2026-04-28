# frozen_string_literal: true

require 'legion/extensions/transport'
require_relative 'exchanges/metering'
require_relative 'exchanges/audit'
require_relative 'exchanges/registry'

module Legion
  module Extensions
    module Llm
      module Ledger
        module Transport
          extend Legion::Extensions::Transport

          def self.additional_e_to_q
            [
              {
                from:        Legion::Extensions::Llm::Ledger::Transport::Exchanges::Metering,
                to:          Legion::Extensions::Llm::Ledger::Transport::Queues::MeteringWrite,
                routing_key: 'metering.#'
              },
              {
                from:        Legion::Extensions::Llm::Ledger::Transport::Exchanges::Audit,
                to:          Legion::Extensions::Llm::Ledger::Transport::Queues::AuditPrompts,
                routing_key: 'audit.prompt.#'
              },
              {
                from:        Legion::Extensions::Llm::Ledger::Transport::Exchanges::Audit,
                to:          Legion::Extensions::Llm::Ledger::Transport::Queues::AuditTools,
                routing_key: 'audit.tool.#'
              },
              {
                from:        Legion::Extensions::Llm::Ledger::Transport::Exchanges::Registry,
                to:          Legion::Extensions::Llm::Ledger::Transport::Queues::RegistryAvailability,
                routing_key: '#'
              }
            ]
          end
        end
      end
    end
  end
end
