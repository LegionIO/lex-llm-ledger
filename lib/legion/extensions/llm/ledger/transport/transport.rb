# frozen_string_literal: true

begin
  require 'legion/extensions/transport'
rescue LoadError => _e
  nil
end

module Legion
  module Extensions
    module LLM
      module Ledger
        module Transport
          extend Legion::Extensions::Transport if Legion::Extensions.const_defined?(:Transport, false)

          def self.additional_e_to_q
            [
              {
                from:        Legion::Extensions::LLM::Ledger::Transport::Exchanges::Metering,
                to:          Legion::Extensions::LLM::Ledger::Transport::Queues::MeteringWrite,
                routing_key: 'metering.#'
              },
              {
                from:        Legion::Extensions::LLM::Ledger::Transport::Exchanges::Audit,
                to:          Legion::Extensions::LLM::Ledger::Transport::Queues::AuditPrompts,
                routing_key: 'audit.prompt.#'
              },
              {
                from:        Legion::Extensions::LLM::Ledger::Transport::Exchanges::Audit,
                to:          Legion::Extensions::LLM::Ledger::Transport::Queues::AuditTools,
                routing_key: 'audit.tool.#'
              }
            ]
          end
        end
      end
    end
  end
end
