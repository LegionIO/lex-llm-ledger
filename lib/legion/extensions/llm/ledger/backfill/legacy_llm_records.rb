# frozen_string_literal: true

module Legion
  module Extensions
    module Llm
      module Ledger
        module Backfill
          module LegacyLlmRecords
            LEGACY_TABLES = %i[
              llm_prompt_records
              llm_metering_records
              llm_tool_records
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
              when :llm_prompt_records
                Writers::OfficialPromptWriter.write(prompt_payload(row))
              when :llm_metering_records
                Writers::OfficialMeteringWriter.write(metering_payload(row))
              when :llm_tool_records
                backfill_tool(row)
              when :llm_registry_availability_records
                backfill_registry(row)
              end
              1
            rescue Sequel::UniqueConstraintViolation => e
              warn("Skipping duplicate legacy LLM row during backfill: #{e.message}")
              0
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
                provider_instance: row[:worker_id],
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
              Writers::OfficialMeteringWriter.write(tool_placeholder_payload(row))
              response = response_for_request(row[:request_id])
              return 0 unless response

              tool_uuid = Writers::OfficialRecordWriter.stable_uuid(row[:tool_call_id] || row[:message_id])
              return 0 if db[:llm_tool_calls].where(uuid: tool_uuid).first

              db[:llm_tool_calls].insert(
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
              )
              1
            end

            def backfill_registry(row)
              uuid = Writers::OfficialRecordWriter.stable_uuid(row[:event_id] || row[:message_id])
              return 0 if db[:llm_registry_events].where(uuid: uuid).first

              db[:llm_registry_events].insert(
                uuid:        uuid,
                provider:    row[:provider_family],
                model_key:   row[:model_id],
                event_type:  row[:event_type],
                status:      registry_status(row),
                reason:      row[:metadata_json],
                recorded_at: row[:occurred_at],
                inserted_at: Time.now.utc
              )
              1
            end

            def tool_placeholder_payload(row)
              {
                message_id:      "tool-meter:#{row[:message_id]}",
                correlation_id:  row[:correlation_id],
                conversation_id: row[:conversation_id],
                request_id:      row[:request_id],
                operation:       'tool',
                provider:        'tool',
                model_id:        row[:tool_name],
                tier:            'tool',
                recorded_at:     row[:tool_start_at] || row[:inserted_at]
              }
            end

            def response_for_request(request_id)
              request = db[:llm_message_inference_requests].where(request_ref: request_id).first
              return nil unless request

              db[:llm_message_inference_responses].where(message_inference_request_id: request[:id]).first
            end

            def next_tool_index(response_id)
              db[:llm_tool_calls].where(message_inference_response_id: response_id).max(:tool_call_index).to_i + 1
            end

            def registry_status(row)
              health = json_load(row[:health_json])
              health[:status] || health['status'] || row[:event_type] || 'unknown'
            end

            def table_present?(table)
              db.table_exists?(table)
            end

            def db
              ::Legion::Data.connection
            end

            def json_load(value)
              return {} if value.nil? || value.to_s.empty?

              if defined?(::Legion::JSON)
                ::Legion::JSON.load(value, symbolize_names: true)
              else
                require 'json'
                ::JSON.parse(value, symbolize_names: true)
              end
            rescue JSON::ParserError => e
              warn("Treating unparsable legacy JSON as content during backfill: #{e.message}")
              { content: value }
            end
          end
        end
      end
    end
  end
end
