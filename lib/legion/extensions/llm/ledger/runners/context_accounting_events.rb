# frozen_string_literal: true

require 'legion/logging'
require 'legion/data/model'
require 'legion/cache/helper'

module Legion
  module Extensions
    module Llm
      module Ledger
        module Runners
          module ContextAccountingEvents
            extend self
            extend Legion::Logging::Helper
            extend Legion::Cache::Helper

            CACHE_TTL = 60

            # rubocop:disable Legion/Extension/RunnerReturnHash

            def fetch(id: nil, uuid: nil, **)
              return by_id(id) if id
              return by_uuid(uuid) if uuid

              nil
            end

            def insert(uuid:, attrs:, **)
              existing = fetch(uuid: uuid)
              return nil if existing

              record = Legion::Data::Models::LLM::ContextAccountingEvent.create(attrs.merge(uuid: uuid))
              cache_record(record)
              record
            rescue Sequel::UniqueConstraintViolation => e
              handle_exception(e, level: :warn, handled: true, operation: 'context_accounting_events.race')
              nil
            end

            def invalidate(id: nil, uuid: nil, **)
              cache_delete("ledger:cae:id:#{id}") if id && cache_available?
              cache_delete("ledger:cae:uuid:#{uuid}") if uuid && cache_available?
              { result: :ok }
            end

            def cache_available?
              Legion::Cache.respond_to?(:connected?) && cache_connected?
            end

            private

            def by_id(id)
              if cache_available?
                cached = cache_get("ledger:cae:id:#{id}")
                return cached if cached
              end

              record = Legion::Data::Models::LLM::ContextAccountingEvent[id]
              cache_record(record) if record
              record
            end

            def by_uuid(uuid)
              if cache_available?
                cached = cache_get("ledger:cae:uuid:#{uuid}")
                return cached if cached
              end

              record = Legion::Data::Models::LLM::ContextAccountingEvent.first(uuid: uuid)
              cache_record(record) if record
              record
            end

            def cache_record(record)
              return unless cache_available? && record

              cache_set("ledger:cae:id:#{record[:id]}", record, ttl: CACHE_TTL)
              cache_set("ledger:cae:uuid:#{record[:uuid]}", record, ttl: CACHE_TTL)
            end

            # rubocop:enable Legion/Extension/RunnerReturnHash
          end
        end
      end
    end
  end
end
