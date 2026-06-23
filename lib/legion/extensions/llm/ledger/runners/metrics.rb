# frozen_string_literal: true

require 'legion/logging'
require 'legion/data/model'
require 'legion/cache/helper'

module Legion
  module Extensions
    module Llm
      module Ledger
        module Runners
          module Metrics
            extend self
            extend Legion::Logging::Helper
            extend Legion::Cache::Helper

            CACHE_TTL = 120

            # rubocop:disable Legion/Extension/RunnerReturnHash

            def fetch(id: nil, uuid: nil, request_id: nil, **)
              return by_id(id) if id
              return by_uuid(uuid) if uuid
              return by_request_id(request_id) if request_id

              nil
            end

            def find_or_create(uuid:, attrs: {}, **)
              existing = fetch(uuid: uuid)
              return existing if existing

              record = Legion::Data::Models::LLM::MessageInferenceMetric.create(attrs.merge(uuid: uuid))
              cache_record(record)
              record
            rescue Sequel::UniqueConstraintViolation => e
              handle_exception(e, level: :debug, handled: true, operation: 'metrics.find_or_create_race')
              fetch(uuid: uuid)
            end

            def invalidate(id: nil, uuid: nil, request_id: nil, **)
              cache_delete("ledger:metric:id:#{id}") if id && cache_available?
              cache_delete("ledger:metric:uuid:#{uuid}") if uuid && cache_available?
              cache_delete("ledger:metric:req:#{request_id}") if request_id && cache_available?
              { result: :ok }
            end

            def cache_available?
              Legion::Cache.respond_to?(:connected?) && cache_connected?
            end

            private

            def by_id(id)
              if cache_available?
                cached = cache_get("ledger:metric:id:#{id}")
                return cached if cached
              end

              record = Legion::Data::Models::LLM::MessageInferenceMetric[id]
              cache_record(record) if record
              record
            end

            def by_uuid(uuid)
              if cache_available?
                cached = cache_get("ledger:metric:uuid:#{uuid}")
                return cached if cached
              end

              record = Legion::Data::Models::LLM::MessageInferenceMetric.first(uuid: uuid)
              cache_record(record) if record
              record
            end

            def by_request_id(request_id)
              if cache_available?
                cached = cache_get("ledger:metric:req:#{request_id}")
                return cached if cached
              end

              record = Legion::Data::Models::LLM::MessageInferenceMetric.first(message_inference_request_id: request_id)
              cache_record(record) if record
              record
            end

            def cache_record(record)
              return unless cache_available? && record

              cache_set("ledger:metric:id:#{record[:id]}", record, ttl: CACHE_TTL)
              cache_set("ledger:metric:uuid:#{record[:uuid]}", record, ttl: CACHE_TTL)
              cache_set("ledger:metric:req:#{record[:message_inference_request_id]}", record, ttl: CACHE_TTL)
            end

            # rubocop:enable Legion/Extension/RunnerReturnHash
          end
        end
      end
    end
  end
end
