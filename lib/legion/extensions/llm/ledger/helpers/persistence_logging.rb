# frozen_string_literal: true

require 'legion/logging'

module Legion
  module Extensions
    module Llm
      module Ledger
        module Helpers
          module PersistenceLogging
            extend Legion::Logging::Helper

            SAFE_CONTEXT_KEYS = %i[
              uuid request_ref correlation_id correlation_ref conversation_id
              message_inference_request_id message_inference_response_id
              response_message_id provider provider_instance model_key tier
              event_id message_id tool_call_id tool_name event_type status
            ].freeze

            module_function

            def insert_row(db, table, attributes, operation:, warn_on_unique: true)
              row_id = db[table].insert(attributes)
              log.info(log_message('inserted', table, operation, row_id, attributes))
              row_id
            rescue Sequel::UniqueConstraintViolation => e
              if warn_on_unique
                log.warn(log_message('insert_failed', table, operation, nil, attributes,
                                     error_class: e.class, error: e.message))
              end
              raise
            rescue StandardError => e
              log.error(log_message('insert_failed', table, operation, nil, attributes,
                                    error_class: e.class, error: e.message))
              handle_exception(e, level: :error, handled: true, operation: operation, table: table)
              raise
            end

            def log_message(action, table, operation, row_id, attributes, error_class: nil, error: nil)
              parts = {
                action:      "ledger.db.#{action}",
                table:       table,
                operation:   operation,
                row_id:      row_id,
                error_class: error_class,
                error:       error
              }.merge(safe_context(attributes)).compact

              parts.map { |key, value| "#{key}=#{value}" }.join(' ')
            end

            def safe_context(attributes)
              attributes.each_with_object({}) do |(key, value), memo|
                normalized_key = key.to_sym
                next unless SAFE_CONTEXT_KEYS.include?(normalized_key)
                next if value.nil? || (value.respond_to?(:empty?) && value.empty?)

                memo[normalized_key] = value
              end
            end
          end
        end
      end
    end
  end
end
