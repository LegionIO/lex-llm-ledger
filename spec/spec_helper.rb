# frozen_string_literal: true

require 'simplecov'
SimpleCov.start

require 'legion/json'
require 'legion/logging'
Legion::Logging.setup(level: 'fatal', log_file: File::NULL, log_stdout: false, async: false)
require 'legion/settings'
require 'securerandom'
require 'sequel'
require_relative 'support/test_db'

module Legion
  module Extensions
    module Core
    end

    module Helpers
      module Logger
        include Legion::Logging::Helper
      end

      module Lex
        include Legion::Extensions::Helpers::Logger

        def self.included(base)
          base.extend(base) if base.instance_of?(Module)
        end
      end
    end

    module Actors
      class UnrecoverableMessageError < StandardError; end

      class Subscription
        include Legion::Logging::Helper
      end

      class Every
        include Legion::Logging::Helper
      end
    end

    module Transport
    end
  end

  module Transport
    class Exchange # rubocop:disable Lint/EmptyClass
    end

    class Queue # rubocop:disable Lint/EmptyClass
    end
  end

  module Data
    @connection = TestDb.setup

    def self.connection
      @connection
    end
  end
end

$LOADED_FEATURES << 'legionio.rb'
$LOADED_FEATURES << 'legion/extensions/core.rb'
$LOADED_FEATURES << 'legion/extensions/actors/subscription'
$LOADED_FEATURES << 'legion/extensions/transport'
$LOADED_FEATURES << 'legion/transport/exchange.rb'
$LOADED_FEATURES << 'legion/transport/queue.rb'

lib = File.expand_path('../lib', __dir__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)

require 'legion/extensions/llm/ledger/version'
require 'legion/extensions/llm/ledger/writers/official_prompt_writer'
require 'legion/extensions/llm/ledger/writers/official_metering_writer'
require 'legion/extensions/llm/ledger/backfill/legacy_llm_records'
require 'legion/extensions/llm/ledger/helpers/queries'
require 'legion/extensions/llm/ledger/helpers/retention'
require 'legion/extensions/llm/ledger/helpers/decryption'
require 'legion/extensions/llm/ledger/helpers/subscription_message'
require 'legion/extensions/llm/ledger/helpers/subscription_actor'
require 'legion/extensions/llm/ledger/helpers/persistence_logging'
require 'legion/extensions/llm/ledger/helpers/caller_identity'
require 'legion/extensions/llm/ledger/runners/metering'
require 'legion/extensions/llm/ledger/runners/prompts'
require 'legion/extensions/llm/ledger/runners/tools'
require 'legion/extensions/llm/ledger/runners/usage_reporter'
require 'legion/extensions/llm/ledger/runners/provider_stats'
require 'legion/extensions/llm/ledger/runners/registry_availability'
require 'legion/extensions/llm/ledger/transport/exchanges/metering'
require 'legion/extensions/llm/ledger/transport/exchanges/audit'
require 'legion/extensions/llm/ledger/transport/exchanges/registry'
require 'legion/extensions/llm/ledger/transport/queues/metering_write'
require 'legion/extensions/llm/ledger/transport/queues/audit_prompts'
require 'legion/extensions/llm/ledger/transport/queues/audit_tools'
require 'legion/extensions/llm/ledger/transport/queues/registry_availability'
require 'legion/extensions/llm/ledger/transport/transport'
require 'legion/extensions/llm/ledger/actors/metering'
require 'legion/extensions/llm/ledger/actors/prompts'
require 'legion/extensions/llm/ledger/actors/tools'
require 'legion/extensions/llm/ledger/actors/registry_availability'
require 'legion/extensions/llm/ledger/actors/spool_flush'

RSpec.configure do |config|
  config.example_status_persistence_file_path = '.rspec_status'
  config.disable_monkey_patching!
  config.expect_with :rspec do |c|
    c.syntax = :expect
  end

  config.before(:each) do
    %i[
      llm_security_events
      llm_policy_evaluations
      llm_tool_call_attempts
      llm_tool_calls
      llm_message_inference_metrics
      llm_route_attempts
      llm_message_inference_responses
      llm_message_inference_requests
      llm_messages
      llm_conversations
      identity_group_memberships
      identity_audit_log
      identities
      identity_groups
      identity_principals
      identity_provider_capabilities
      identity_providers
    ].each do |table|
      Legion::Data.connection[table].delete if Legion::Data.connection.table_exists?(table)
    end

    Legion::Data.connection[:llm_metering_records].delete
    Legion::Data.connection[:llm_prompt_records].delete
    Legion::Data.connection[:llm_tool_records].delete
    Legion::Data.connection[:llm_registry_availability_records].delete
  end
end
