# frozen_string_literal: true

require 'legion/json'
require 'legion/logging'
require 'legion/settings'
require_relative 'ledger/version'
require_relative 'ledger/helpers/json'
require_relative 'ledger/helpers/decryption'
require_relative 'ledger/helpers/retention'
require_relative 'ledger/helpers/queries'
require_relative 'ledger/helpers/subscription_message'
require_relative 'ledger/helpers/subscription_actor'
require_relative 'ledger/helpers/caller_identity'
require_relative 'ledger/writers/official_prompt_writer'
require_relative 'ledger/writers/official_metering_writer'
require_relative 'ledger/backfill/legacy_llm_records'
require_relative 'ledger/runners/metering'
require_relative 'ledger/runners/prompts'
require_relative 'ledger/runners/tools'
require_relative 'ledger/runners/usage_reporter'
require_relative 'ledger/runners/provider_stats'
require_relative 'ledger/runners/registry_availability'

if defined?(Legion::Extensions) && Legion::Extensions.const_defined?(:Core, false)
  require_relative 'ledger/transport/exchanges/metering'
  require_relative 'ledger/transport/exchanges/audit'
  require_relative 'ledger/transport/exchanges/registry'
  require_relative 'ledger/transport/queues/metering_write'
  require_relative 'ledger/transport/queues/audit_prompts'
  require_relative 'ledger/transport/queues/audit_tools'
  require_relative 'ledger/transport/queues/registry_availability'
  require_relative 'ledger/transport/transport'
  require_relative 'ledger/actors/metering_writer'
  require_relative 'ledger/actors/prompt_writer'
  require_relative 'ledger/actors/tool_writer'
  require_relative 'ledger/actors/registry_availability_writer'
  require_relative 'ledger/actors/spool_flush'
end

module Legion
  module Extensions
    module Llm
      module Ledger
        extend Legion::Extensions::Core if Legion::Extensions.const_defined?(:Core, false)
        extend Legion::Logging::Helper

        def self.data_required? # rubocop:disable Legion/Extension/DataRequiredWithoutMigrations
          true
        end

        def self.default_settings
          {
            remote_invocable: false,
            retention:        {
              default_days: 90,
              phi_ttl_days: 30
            }
          }
        end

        def self.remote_invocable?
          configured = Legion::Settings.dig(:extensions, :llm, :ledger, :remote_invocable) if defined?(Legion::Settings)
          return configured unless configured.nil?

          false
        end

        def data_required?
          true
        end
      end
    end
  end
end
