# frozen_string_literal: true

require 'digest'
require 'legion/logging'
require 'legion/data/model'
require 'legion/cache/helper'

module Legion
  module Extensions
    module Llm
      module Ledger
        module Runners
          module Requests
            extend self
            extend Legion::Logging::Helper
            extend Legion::Cache::Helper

            CACHE_TTL = 120

            # rubocop:disable Legion/Extension/RunnerReturnHash

            def fetch(id: nil, uuid: nil, ref: nil, **)
              return by_id(id) if id
              return by_uuid(uuid) if uuid
              return by_ref(ref) if ref

              nil
            end

            def find_or_create(uuid:, attrs: {}, **)
              existing = fetch(uuid: uuid)
              return existing if existing

              record = Legion::Data::Models::LLM::MessageInferenceRequest.create(attrs.merge(uuid: uuid))
              result = record.values
              cache_record(result)
              result
            rescue Sequel::UniqueConstraintViolation => e
              handle_exception(e, level: :warn, handled: true, operation: 'requests.find_or_create_race')
              fetch(uuid: uuid)
            end

            def enrich(record:, updates:, **)
              return record if updates.nil? || updates.empty?

              Legion::Data::Models::LLM::MessageInferenceRequest.where(id: record[:id]).update(updates)
              invalidate(id: record[:id], uuid: record[:uuid], ref: record[:request_ref])
              record.merge(updates)
            end

            def invalidate(id: nil, uuid: nil, ref: nil, **)
              cache_delete("ledger:req:id:#{id}") if id && cache_available?
              cache_delete("ledger:req:uuid:#{uuid}") if uuid && cache_available?
              cache_delete("ledger:req:ref:#{ref}") if ref && cache_available?
              { result: :ok }
            end

            def cache_available?
              Legion::Cache.respond_to?(:connected?) && cache_connected?
            end

            private

            def by_id(id)
              if cache_available?
                cached = cache_get("ledger:req:id:#{id}")
                return cached if cached
              end

              record = Legion::Data::Models::LLM::MessageInferenceRequest[id]
              return nil unless record

              result = record.values
              cache_record(result)
              result
            end

            def by_uuid(uuid)
              if cache_available?
                cached = cache_get("ledger:req:uuid:#{uuid}")
                return cached if cached
              end

              record = Legion::Data::Models::LLM::MessageInferenceRequest.first(uuid: uuid)
              return nil unless record

              result = record.values
              cache_record(result)
              result
            end

            def by_ref(ref)
              if cache_available?
                cached = cache_get("ledger:req:ref:#{ref}")
                return cached if cached
              end

              record = Legion::Data::Models::LLM::MessageInferenceRequest.first(request_ref: ref) ||
                       Legion::Data::Models::LLM::MessageInferenceRequest.first(uuid: stable_uuid(ref))
              return nil unless record

              result = record.values
              cache_record(result)
              result
            end

            def stable_uuid(value)
              raw = value.to_s
              return raw if raw.length <= 36

              hex = Digest::SHA256.hexdigest(raw)[0, 32]
              "#{hex[0, 8]}-#{hex[8, 4]}-#{hex[12, 4]}-#{hex[16, 4]}-#{hex[20, 12]}"
            end

            def cache_record(result)
              return unless cache_available? && result

              cache_set("ledger:req:id:#{result[:id]}", result, ttl: CACHE_TTL)
              cache_set("ledger:req:uuid:#{result[:uuid]}", result, ttl: CACHE_TTL)
              cache_set("ledger:req:ref:#{result[:request_ref]}", result, ttl: CACHE_TTL) if result[:request_ref]
            end

            # rubocop:enable Legion/Extension/RunnerReturnHash
          end
        end
      end
    end
  end
end
