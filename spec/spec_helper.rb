# frozen_string_literal: true

require 'simplecov'
SimpleCov.start

require 'legion/json'
require 'legion/logging'
Legion::Logging.setup(level: 'fatal', log_file: File::NULL, log_stdout: false, async: false)
require 'legion/data/model'
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

        def self.consumers(count = nil)
          @consumers = count unless count.nil?
          @consumers
        end

        def self.prefetch(count = nil)
          @prefetch = count unless count.nil?
          @prefetch
        end
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

Legion::Data::Models.instance_variable_set(:@loaded_models, []) unless Legion::Data::Models.loaded_models
Legion::Data::Models.require_sequel_models(%w[
                                             llm/conversation
                                             llm/message
                                             llm/message_inference_request
                                             llm/message_inference_response
                                             llm/message_inference_metric
                                             llm/tool_call
                                             llm/tool_call_attempt
                                             llm/route_attempt
                                           ])

$LOADED_FEATURES << 'legionio.rb'
$LOADED_FEATURES << 'legion/extensions/core.rb'
$LOADED_FEATURES << 'legion/extensions/actors/subscription'
$LOADED_FEATURES << 'legion/extensions/transport'
$LOADED_FEATURES << 'legion/transport/exchange.rb'
$LOADED_FEATURES << 'legion/transport/queue.rb'

lib = File.expand_path('../lib', __dir__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)

require 'legion/extensions/llm/responses/thinking_extractor'
require 'legion/extensions/llm/ledger/version'
require 'legion/extensions/llm/ledger/helpers/identity_resolution'
require 'legion/extensions/llm/ledger/runners/conversations'
require 'legion/extensions/llm/ledger/runners/messages'
require 'legion/extensions/llm/ledger/runners/requests'
require 'legion/extensions/llm/ledger/runners/responses'
require 'legion/extensions/llm/ledger/runners/metering'
require 'legion/extensions/llm/ledger/runners/prompts'
require 'legion/extensions/llm/ledger/runners/tools'
require 'legion/extensions/llm/ledger/runners/skills'
require 'legion/extensions/llm/ledger/runners/escalations'
require 'legion/extensions/llm/ledger/runners/usage_reporter'
require 'legion/extensions/llm/ledger/runners/provider_stats'
require 'legion/extensions/llm/ledger/runners/registry_availability'
require 'legion/extensions/llm/ledger/runners/retention_purge'
require 'legion/extensions/llm/ledger/runners/reconciliation'
require 'legion/extensions/llm/ledger/transport/exchanges/metering'
require 'legion/extensions/llm/ledger/transport/exchanges/audit'
require 'legion/extensions/llm/ledger/transport/exchanges/registry'
require 'legion/extensions/llm/ledger/transport/queues/metering_write'
require 'legion/extensions/llm/ledger/transport/queues/audit_prompts'
require 'legion/extensions/llm/ledger/transport/queues/audit_tools'
require 'legion/extensions/llm/ledger/transport/queues/audit_skills'
require 'legion/extensions/llm/ledger/transport/queues/audit_escalations'
require 'legion/extensions/llm/ledger/transport/queues/registry_availability'
require 'legion/extensions/llm/ledger/transport/transport'
require 'legion/extensions/llm/ledger/actors/metering'
require 'legion/extensions/llm/ledger/actors/prompts'
require 'legion/extensions/llm/ledger/actors/tools'
require 'legion/extensions/llm/ledger/actors/skills'
require 'legion/extensions/llm/ledger/actors/escalations'
require 'legion/extensions/llm/ledger/actors/registry_availability'

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
      Legion::Data::Models::LLM::Conversation.db[table].delete if Legion::Data::Models::LLM::Conversation.db.table_exists?(table)
    end

    Legion::Data::Models::LLM::Conversation.db[:z_archive_llm_metering_records].delete
    Legion::Data::Models::LLM::Conversation.db[:z_archive_llm_prompt_records].delete
    Legion::Data::Models::LLM::Conversation.db[:z_archive_llm_tool_records].delete
    Legion::Data::Models::LLM::Conversation.db[:llm_registry_availability_records].delete
  end
end
