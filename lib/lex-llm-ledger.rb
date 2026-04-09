# frozen_string_literal: true

require 'legion/extensions/llm/ledger/version'
require 'legion/extensions/llm/ledger/helpers/decryption'
require 'legion/extensions/llm/ledger/helpers/retention'
require 'legion/extensions/llm/ledger/helpers/queries'
require 'legion/extensions/llm/ledger/runners/metering'
require 'legion/extensions/llm/ledger/runners/prompts'
require 'legion/extensions/llm/ledger/runners/tools'
require 'legion/extensions/llm/ledger/runners/usage_reporter'
require 'legion/extensions/llm/ledger/runners/provider_stats'

if Legion::Extensions.const_defined?(:Core, false)
  require 'legion/extensions/llm/ledger/transport/exchanges/metering'
  require 'legion/extensions/llm/ledger/transport/exchanges/audit'
  require 'legion/extensions/llm/ledger/transport/queues/metering_write'
  require 'legion/extensions/llm/ledger/transport/queues/audit_prompts'
  require 'legion/extensions/llm/ledger/transport/queues/audit_tools'
  require 'legion/extensions/llm/ledger/transport/transport'
  require 'legion/extensions/llm/ledger/actors/metering_writer'
  require 'legion/extensions/llm/ledger/actors/prompt_writer'
  require 'legion/extensions/llm/ledger/actors/tool_writer'
  require 'legion/extensions/llm/ledger/actors/spool_flush'
end

module Legion
  module Extensions
    module LLM
      module Ledger
        extend Legion::Extensions::Core if Legion::Extensions.const_defined?(:Core, false)

        def self.data_required?
          true
        end

        def data_required?
          true
        end
      end
    end
  end
end
