# frozen_string_literal: true

require 'legion/logging'
require_relative '../helpers/json'
require_relative '../helpers/persistence_logging'

module Legion
  module Extensions
    module Llm
      module Ledger
        module Backfill
          module LegacyLlmRecords
            extend Legion::Logging::Helper

            LEGACY_TABLES = %i[
              z_archive_llm_prompt_records
              z_archive_llm_metering_records
              z_archive_llm_tool_records
              llm_registry_availability_records
            ].freeze

            module_function

            def run(limit: nil, writer_mode: :official)
              ensure_no_legacy_writer_mode!(writer_mode)

              LEGACY_TABLES.to_h do |table|
                [table, table_present?(table) ? backfill_table(table, limit:) : 0]
              end
            end

            def ensure_no_legacy_writer_mode!(mode)
              return unless %i[legacy legacy_only legacy_table_only].include?(mode.to_sym)

              raise ArgumentError, 'Legacy LLM writer mode is disabled after official backfill; configure official LLM writers.'
            end

            def backfill_table(table, limit:)
              dataset = db[table].order(:id)
              dataset = dataset.limit(limit) if limit
              dataset.all.sum { |row| backfill_row(table, row) }
            end

            def backfill_row(table, row)
              case table
              when :z_archive_llm_prompt_records
                backfill_prompt(row)
              when :z_archive_llm_metering_records
                backfill_metering(row)
              when :z_archive_llm_tool_records
                backfill_tool(row)
              when :llm_registry_availability_records
                backfill_registry(row)
              end
            rescue Sequel::UniqueConstraintViolation => e
              handle_exception(e, level: :warn, handled: true, operation: 'legacy_llm_backfill.duplicate')
              0
            end

            def backfill_prompt(row)
              payload = prompt_payload(row)
              return 0 if official_metric_exists?(payload)

              Writers::OfficialPromptWriter.write(payload)
              1
            end

            def backfill_metering(row)
              payload = metering_payload(row)
              return 0 if official_metric_exists?(payload)

              Writers::OfficialMeteringWriter.write(payload)
              1
            end

            def prompt_payload(row)
              {
                message_id:           row[:message_id],
                correlation_id:       row[:correlation_id],
                conversation_id:      row[:conversation_id],
                response_message_id:  row[:response_message_id],
                request_id:           row[:request_id],
                exchange_id:          row[:exchange_id],
                operation:            row[:request_type],
                provider:             row[:provider],
                model_id:             row[:model_id],
                tier:                 row[:tier],
                request:              json_load(row[:request_json]),
                response:             json_load(row[:response_json]),
                response_thinking:    json_load(row[:response_thinking_json]),
                input_tokens:         row[:input_tokens],
                output_tokens:        row[:output_tokens],
                total_tokens:         row[:total_tokens],
                cost_usd:             row[:cost_usd],
                classification_level: row[:classification_level],
                contains_phi:         row[:contains_phi],
                contains_pii:         row[:contains_pii],
                retention_policy:     row[:retention_policy],
                expires_at:           row[:expires_at],
                recorded_at:          row[:recorded_at]
              }
            end

            def metering_payload(row)
              {
                message_id:        row[:message_id],
                correlation_id:    row[:correlation_id],
                conversation_id:   row[:conversation_id],
                request_id:        row[:request_id],
                exchange_id:       row[:exchange_id],
                operation:         row[:request_type],
                provider:          row[:provider],
                provider_instance: row[:provider_instance],
                worker_id:         row[:worker_id],
                model_id:          row[:model_id],
                tier:              row[:tier],
                input_tokens:      row[:input_tokens],
                output_tokens:     row[:output_tokens],
                thinking_tokens:   row[:thinking_tokens],
                total_tokens:      row[:total_tokens],
                latency_ms:        row[:latency_ms],
                wall_clock_ms:     row[:wall_clock_ms],
                cost_usd:          row[:cost_usd],
                recorded_at:       row[:recorded_at],
                billing:           {
                  cost_center: row[:cost_center],
                  budget_id:   row[:budget_id]
                }
              }
            end

            def backfill_tool(row)
              response = response_for_request(row[:request_id])
              return 0 unless response

              tool_uuid = Writers::OfficialRecordWriter.stable_uuid(row[:tool_call_id] || row[:message_id])
              return 0 if db[:llm_tool_calls].where(uuid: tool_uuid).first

              insert_row(:llm_tool_calls, {
                           uuid:                          tool_uuid,
                           message_inference_response_id: response[:id],
                           tool_call_index:               next_tool_index(response[:id]),
                           provider_tool_call_ref:        row[:tool_call_id],
                           tool_name:                     row[:tool_name],
                           tool_source_type:              row[:tool_source_type],
                           tool_source_server:            row[:tool_source_server],
                           status:                        row[:tool_status],
                           requested_at:                  row[:tool_start_at],
                           completed_at:                  row[:tool_end_at],
                           inserted_at:                   Time.now.utc
                         }, operation: 'legacy_llm_backfill.tool_call')
              1
            end

            def backfill_registry(row)
              uuid = Writers::OfficialRecordWriter.stable_uuid(row[:event_id] || row[:message_id])
              return 0 if db[:llm_registry_events].where(uuid: uuid).first

              insert_row(:llm_registry_events, {
                           uuid:        uuid,
                           provider:    row[:provider_family],
                           model_key:   row[:model_id],
                           event_type:  row[:event_type],
                           status:      registry_status(row),
                           reason:      registry_reason(row),
                           recorded_at: row[:occurred_at],
                           inserted_at: Time.now.utc
                         }, operation: 'legacy_llm_backfill.registry_event')
              1
            end

            def insert_row(table, attributes, operation:)
              Helpers::PersistenceLogging.insert_row(db, table, attributes, operation: operation)
            end

            def response_for_request(request_id)
              request = db[:llm_message_inference_requests].where(request_ref: request_id).first
              return nil unless request

              db[:llm_message_inference_responses].where(message_inference_request_id: request[:id]).first
            end

            def official_metric_exists?(payload)
              db[:llm_message_inference_metrics].where(uuid: official_metric_uuid(payload)).first
            end

            def official_metric_uuid(payload)
              ref = payload[:metric_id] || payload[:metric_ref] || "metric:#{Writers::OfficialRecordWriter.request_ref(payload)}"
              Writers::OfficialRecordWriter.stable_uuid(ref)
            end

            def next_tool_index(response_id)
              db[:llm_tool_calls].where(message_inference_response_id: response_id).max(:tool_call_index).to_i + 1
            end

            def registry_status(row)
              health = json_load(row[:health_json])
              health[:status] || health['status'] || row[:event_type] || 'unknown'
            end

            def registry_reason(row)
              metadata = json_load(row[:metadata_json])
              metadata[:reason] || metadata['reason'] || metadata[:message] || metadata['message'] || row[:event_type]
            end

            def table_present?(table)
              db.table_exists?(table)
            end

            def db
              ::Legion::Data.connection
            end

            def json_load(value)
              return {} if value.nil? || value.to_s.empty?

              Helpers::Json.load(value)
            rescue StandardError => e
              raise unless Helpers::Json.parse_error?(e)

              handle_exception(e, level: :warn, handled: true, operation: 'legacy_llm_backfill.json_load')
              { content: value }
            end
          end
        end
      end
    end
  end
end
