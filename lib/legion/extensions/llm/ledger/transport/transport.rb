# frozen_string_literal: true

begin
  require 'legion/extensions/transport'
  require 'legion/llm/transport/exchanges/audit'
  require 'legion/llm/transport/exchanges/escalation'
  require 'legion/llm/transport/exchanges/metering'
rescue LoadError => _e
  nil
end

module Legion
  module Extensions
    module Llm
      module Ledger
        module Transport
          extend Legion::Extensions::Transport if Legion::Extensions.const_defined?(:Transport, false)

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
