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
              cache_record(record)
              record
            rescue Sequel::UniqueConstraintViolation => e
              handle_exception(e, level: :warn, handled: true, operation: 'responses.find_or_create_race')
              fetch(uuid: uuid)
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
              cache_record(record) if record
              record
            end

            def by_uuid(uuid)
              if cache_available?
                cached = cache_get("ledger:resp:uuid:#{uuid}")
                return cached if cached
              end

              record = Legion::Data::Models::LLM::MessageInferenceResponse.first(uuid: uuid)
              cache_record(record) if record
              record
            end

            def by_request_id(request_id)
              if cache_available?
                cached = cache_get("ledger:resp:req:#{request_id}")
                return cached if cached
              end

              record = Legion::Data::Models::LLM::MessageInferenceResponse.first(message_inference_request_id: request_id)
              cache_record(record) if record
              record
            end

            def cache_record(record)
              return unless cache_available? && record

              cache_set("ledger:resp:id:#{record[:id]}", record, ttl: CACHE_TTL)
              cache_set("ledger:resp:uuid:#{record[:uuid]}", record, ttl: CACHE_TTL)
              cache_set("ledger:resp:req:#{record[:message_inference_request_id]}", record, ttl: CACHE_TTL)
            end

            # rubocop:enable Legion/Extension/RunnerReturnHash
          end
        end
      end
    end
  end
end
