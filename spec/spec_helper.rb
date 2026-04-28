# frozen_string_literal: true

require 'simplecov'
SimpleCov.start

require 'securerandom'
require 'sequel'
require_relative 'support/test_db'

module Legion
  module Extensions
    module Core
    end

    module Helpers
      module Lex
        def self.included(base)
          base
        end
      end
    end

    module Actors
      class Subscription # rubocop:disable Lint/EmptyClass
      end

      class Every # rubocop:disable Lint/EmptyClass
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

  module Logging
    def self.error(_msg) = nil
    def self.warn(_msg)  = nil
    def self.info(_msg)  = nil
    def self.debug(_msg) = nil
  end

  module JSON
    def self.dump(obj)
      require 'json'
      ::JSON.generate(obj)
    end

    def self.load(str, symbolize_names: false)
      require 'json'
      ::JSON.parse(str, symbolize_names: symbolize_names)
    end
  end

  module Data
    DB = TestDb.setup

    def self.db
      DB
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
require 'legion/extensions/llm/ledger/helpers/queries'
require 'legion/extensions/llm/ledger/helpers/retention'
require 'legion/extensions/llm/ledger/helpers/decryption'
require 'legion/extensions/llm/ledger/helpers/subscription_message'
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
require 'legion/extensions/llm/ledger/actors/metering_writer'
require 'legion/extensions/llm/ledger/actors/prompt_writer'
require 'legion/extensions/llm/ledger/actors/tool_writer'
require 'legion/extensions/llm/ledger/actors/registry_availability_writer'
require 'legion/extensions/llm/ledger/actors/spool_flush'

RSpec.configure do |config|
  config.example_status_persistence_file_path = '.rspec_status'
  config.disable_monkey_patching!
  config.expect_with :rspec do |c|
    c.syntax = :expect
  end

  config.before(:each) do
    Legion::Data::DB[:metering_records].delete
    Legion::Data::DB[:prompt_records].delete
    Legion::Data::DB[:tool_records].delete
    Legion::Data::DB[:registry_availability_records].delete
  end
end
