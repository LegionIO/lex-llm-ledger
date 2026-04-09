# frozen_string_literal: true

require_relative 'ledger/version'
require_relative 'ledger/helpers/decryption'
require_relative 'ledger/helpers/retention'
require_relative 'ledger/helpers/queries'
require_relative 'ledger/runners/metering'
require_relative 'ledger/runners/prompts'
require_relative 'ledger/runners/tools'
require_relative 'ledger/runners/usage_reporter'
require_relative 'ledger/runners/provider_stats'

if Legion::Extensions.const_defined?(:Core, false)
  require_relative 'ledger/transport/exchanges/metering'
  require_relative 'ledger/transport/exchanges/audit'
  require_relative 'ledger/transport/queues/metering_write'
  require_relative 'ledger/transport/queues/audit_prompts'
  require_relative 'ledger/transport/queues/audit_tools'
  require_relative 'ledger/transport/transport'
  require_relative 'ledger/actors/metering_writer'
  require_relative 'ledger/actors/prompt_writer'
  require_relative 'ledger/actors/tool_writer'
  require_relative 'ledger/actors/spool_flush'
end

module Legion
  module Extensions
    module LLM
      module Ledger
        extend Legion::Extensions::Core if Legion::Extensions.const_defined?(:Core, false)

        def self.data_required? # rubocop:disable Legion/Extension/DataRequiredWithoutMigrations
          true
        end

        def data_required?
          true
        end
      end
    end
  end
end
