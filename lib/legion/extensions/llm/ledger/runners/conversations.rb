# frozen_string_literal: true

require 'legion/logging'
require 'legion/data/model'
require 'legion/cache/helper'

module Legion
  module Extensions
    module Llm
      module Ledger
        module Runners
          module Conversations
            extend self # rubocop:disable Style/ModuleFunction
            extend Legion::Logging::Helper
            extend Legion::Cache::Helper

            CACHE_TTL = 300

            # rubocop:disable Legion/Extension/RunnerReturnHash
            def fetch(id: nil, uuid: nil, **)
              if id
                record = Legion::Data::Models::LLM::Conversation[id]
                return record
              end

              return nil unless uuid

              if cache_available?
                cached = cache_get("ledger:conv:#{uuid}")
                return cached if cached
              end

              record = Legion::Data::Models::LLM::Conversation.first(uuid: uuid)
              cache_set("ledger:conv:#{uuid}", record, ttl: CACHE_TTL) if record && cache_available?
              record
            end

            def find_or_create(uuid:, attrs: {}, **)
              existing = fetch(uuid: uuid)
              return existing if existing

              record = Legion::Data::Models::LLM::Conversation.create(attrs.merge(uuid: uuid))
              cache_set("ledger:conv:#{uuid}", record, ttl: CACHE_TTL) if cache_available?
              record
            rescue Sequel::UniqueConstraintViolation => e
              handle_exception(e, level: :debug, handled: true, operation: 'conversations.find_or_create_race')
              fetch(uuid: uuid)
            end
            # rubocop:enable Legion/Extension/RunnerReturnHash

            def invalidate(uuid:, **)
              cache_delete("ledger:conv:#{uuid}") if cache_available?
              { result: :ok }
            end

            def cache_available?
              Legion::Cache.respond_to?(:connected?) && cache_connected?
            end
          end
        end
      end
    end
  end
end
