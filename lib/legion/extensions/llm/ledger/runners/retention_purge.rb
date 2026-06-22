# frozen_string_literal: true

require 'legion/logging'

module Legion
  module Extensions
    module Llm
      module Ledger
        module Runners
          module RetentionPurge
            extend self
            extend Legion::Logging::Helper

            PURGEABLE_TABLES = %i[
              llm_conversations
            ].freeze

            BATCH_SIZE = 500

            def purge_expired
              total_deleted = 0

              PURGEABLE_TABLES.each do |table|
                next unless purge_relation(table).first_source

                deleted = purge_table(table)
                total_deleted += deleted
                log.info("[ledger] retention_purge: deleted #{deleted} expired rows from #{table}") if deleted.positive?
              end

              { result: :ok, deleted: total_deleted }
            rescue StandardError => e
              handle_exception(e, level: :error, handled: true, operation: 'retention_purge')
              { result: :error, error: e.message }
            end

            private

            def purge_table(table)
              deleted = 0
              relation = purge_relation(table)
              loop do
                ids = relation.where { expires_at <= Time.now.utc }
                              .where(Sequel.~(expires_at: nil))
                              .select(:id)
                              .limit(BATCH_SIZE)
                              .select_map(:id)
                break if ids.empty?

                relation.where(id: ids).delete
                deleted += ids.size
                break if ids.size < BATCH_SIZE
              end
              deleted
            end

            def purge_relation(table)
              Legion::Data::Models::LLM::Conversation.dataset.from(table)
            end
          end
        end
      end
    end
  end
end
