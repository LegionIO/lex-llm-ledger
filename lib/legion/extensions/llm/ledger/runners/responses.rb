# frozen_string_literal: true

require 'legion/logging'
require 'legion/data/model'
require 'legion/cache/helper'

module Legion
  module Extensions
    module Llm
      module Ledger
        module Runners
          module Responses
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

              record = Legion::Data::Models::LLM::MessageInferenceResponse.create(attrs.merge(uuid: uuid))
              result = record.values
              cache_record(result)
              result
            rescue Sequel::UniqueConstraintViolation => e
              handle_exception(e, level: :warn, handled: true, operation: 'responses.find_or_create_race')
              fetch(uuid: uuid)
            end

            def enrich(record:, updates:, **)
              return record if updates.nil? || updates.empty?

              Legion::Data::Models::LLM::MessageInferenceResponse.where(id: record[:id]).update(updates)
              invalidate(id: record[:id], uuid: record[:uuid], request_id: record[:message_inference_request_id])
              record.merge(updates)
            end

            def invalidate(id: nil, uuid: nil, request_id: nil, **)
              cache_delete("ledger:resp:id:#{id}") if id && cache_available?
              cache_delete("ledger:resp:uuid:#{uuid}") if uuid && cache_available?
              cache_delete("ledger:resp:req:#{request_id}") if request_id && cache_available?
              { result: :ok }
            end

            def cache_available?
              Legion::Cache.respond_to?(:connected?) && cache_connected?
            end

            private

            def by_id(id)
              if cache_available?
                cached = cache_get("ledger:resp:id:#{id}")
                return cached if cached
              end

              record = Legion::Data::Models::LLM::MessageInferenceResponse[id]
              return nil unless record

              result = record.values
              cache_record(result)
              result
            end

            def by_uuid(uuid)
              if cache_available?
                cached = cache_get("ledger:resp:uuid:#{uuid}")
                return cached if cached
              end

              record = Legion::Data::Models::LLM::MessageInferenceResponse.first(uuid: uuid)
              return nil unless record

              result = record.values
              cache_record(result)
              result
            end

            def by_request_id(request_id)
              if cache_available?
                cached = cache_get("ledger:resp:req:#{request_id}")
                return cached if cached
              end

              record = Legion::Data::Models::LLM::MessageInferenceResponse.first(message_inference_request_id: request_id)
              return nil unless record

              result = record.values
              cache_record(result)
              result
            end

            def cache_record(result)
              return unless cache_available? && result

              cache_set("ledger:resp:id:#{result[:id]}", result, ttl: CACHE_TTL)
              cache_set("ledger:resp:uuid:#{result[:uuid]}", result, ttl: CACHE_TTL)
              cache_set("ledger:resp:req:#{result[:message_inference_request_id]}", result, ttl: CACHE_TTL)
            end

            # rubocop:enable Legion/Extension/RunnerReturnHash
          end
        end
      end
    end
  end
end
