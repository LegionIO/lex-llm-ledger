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
          module Conversations
            extend self
            extend Legion::Logging::Helper
            extend Legion::Cache::Helper

            CACHE_TTL = 300

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

              record = Legion::Data::Models::LLM::Conversation.create(attrs.merge(uuid: uuid))
              cache_record(record)
              record
            rescue Sequel::UniqueConstraintViolation => e
              handle_exception(e, level: :warn, handled: true, operation: 'conversations.find_or_create_race')
              fetch(uuid: uuid)
            end

            def invalidate(id: nil, uuid: nil, **)
              cache_delete("ledger:conv:id:#{id}") if id && cache_available?
              cache_delete("ledger:conv:uuid:#{uuid}") if uuid && cache_available?
              { result: :ok }
            end

            def cache_available?
              Legion::Cache.respond_to?(:connected?) && cache_connected?
            end

            private

            def by_id(id)
              if cache_available?
                cached = cache_get("ledger:conv:id:#{id}")
                return cached if cached
              end

              record = Legion::Data::Models::LLM::Conversation[id]
              cache_record(record) if record
              record
            end

            def by_uuid(uuid)
              if cache_available?
                cached = cache_get("ledger:conv:uuid:#{uuid}")
                return cached if cached
              end

              record = Legion::Data::Models::LLM::Conversation.first(uuid: uuid)
              cache_record(record) if record
              record
            end

            def by_ref(ref)
              derived = stable_uuid(ref)
              record = by_uuid(derived)
              return record if record

              # ref may already be a raw UUID string — try it directly when it
              # differs from the derived value (i.e. ref was <=36 chars and was
              # returned as-is, so derived == ref and we already tried it above)
              return nil if derived == ref.to_s

              by_uuid(ref.to_s)
            end

            def stable_uuid(value)
              raw = value.to_s
              return raw if raw.length <= 36

              hex = Digest::SHA256.hexdigest(raw)[0, 32]
              "#{hex[0, 8]}-#{hex[8, 4]}-#{hex[12, 4]}-#{hex[16, 4]}-#{hex[20, 12]}"
            end

            def cache_record(record)
              return unless cache_available? && record

              cache_set("ledger:conv:id:#{record[:id]}", record, ttl: CACHE_TTL)
              cache_set("ledger:conv:uuid:#{record[:uuid]}", record, ttl: CACHE_TTL)
            end

            # rubocop:enable Legion/Extension/RunnerReturnHash
          end
        end
      end
    end
  end
end
