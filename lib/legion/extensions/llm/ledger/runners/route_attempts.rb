# frozen_string_literal: true

require 'legion/logging'
require 'legion/data/model'
require 'legion/cache/helper'

module Legion
  module Extensions
    module Llm
      module Ledger
        module Runners
          module RouteAttempts
            extend self
            extend Legion::Logging::Helper
            extend Legion::Cache::Helper

            CACHE_TTL = 120

            # rubocop:disable Legion/Extension/RunnerReturnHash

            def fetch(id: nil, uuid: nil, **)
              return by_id(id) if id
              return by_uuid(uuid) if uuid

              nil
            end

            def insert(uuid:, attrs:, **)
              existing = fetch(uuid: uuid)
              return nil if existing

              record = Legion::Data::Models::LLM::RouteAttempt.create(attrs.merge(uuid: uuid))
              result = record.values
              cache_record(result)
              result
            rescue Sequel::UniqueConstraintViolation => e
              handle_exception(e, level: :warn, handled: true, operation: 'route_attempts.race')
              nil
            end

            def invalidate(id: nil, uuid: nil, **)
              cache_delete("ledger:route:id:#{id}") if id && cache_available?
              cache_delete("ledger:route:uuid:#{uuid}") if uuid && cache_available?
              { result: :ok }
            end

            def cache_available?
              Legion::Cache.respond_to?(:connected?) && cache_connected?
            end

            private

            def by_id(id)
              if cache_available?
                cached = cache_get("ledger:route:id:#{id}")
                return cached if cached
              end

              record = Legion::Data::Models::LLM::RouteAttempt[id]
              return nil unless record

              result = record.values
              cache_record(result)
              result
            end

            def by_uuid(uuid)
              if cache_available?
                cached = cache_get("ledger:route:uuid:#{uuid}")
                return cached if cached
              end

              record = Legion::Data::Models::LLM::RouteAttempt.first(uuid: uuid)
              return nil unless record

              result = record.values
              cache_record(result)
              result
            end

            def cache_record(result)
              return unless cache_available? && result

              cache_set("ledger:route:id:#{result[:id]}", result, ttl: CACHE_TTL)
              cache_set("ledger:route:uuid:#{result[:uuid]}", result, ttl: CACHE_TTL)
            end

            # rubocop:enable Legion/Extension/RunnerReturnHash
          end
        end
      end
    end
  end
end
