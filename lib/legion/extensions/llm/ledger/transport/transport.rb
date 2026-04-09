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
                exchange: Exchanges::Metering,
                queue:    Queues::MeteringWrite,
                binding:  'metering.#'
              },
              {
                exchange: Exchanges::Audit,
                queue:    Queues::AuditPrompts,
                binding:  'audit.prompt.#'
              },
              {
                exchange: Exchanges::Audit,
                queue:    Queues::AuditTools,
                binding:  'audit.tool.#'
              }
            ]
          end
        end
      end
    end
  end
end
