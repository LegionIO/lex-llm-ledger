# frozen_string_literal: true

module Legion
  module Extensions
    module Llm
      module Ledger
        module Runners
          module Metering
            extend self

            def spool_flush
              return unless defined?(Legion::LLM::Metering) &&
                            Legion::LLM::Metering.respond_to?(:flush_spool)

              Legion::LLM::Metering.flush_spool
              { result: :ok }
            rescue StandardError => e
              Legion::Logging.warn("[lex-llm-ledger] spool_flush failed: #{e.message}") # rubocop:disable Legion/HelperMigration/DirectLogging
              { result: :error, error: e.message }
            end

            def write_metering_record(payload, metadata = {})
              ctx   = payload[:message_context] || {}
              props = metadata[:properties] || {}

              record = build_metering_record(payload, ctx, props)
              ::Legion::Data::DB[:metering_records].insert(record)
              { result: :ok }
            rescue Sequel::UniqueConstraintViolation => _e
              { result: :duplicate }
            rescue StandardError => e
              Legion::Logging.error("[lex-llm-ledger] write_metering_record failed: #{e.message}") # rubocop:disable Legion/HelperMigration/DirectLogging
              { result: :error, error: e.message }
            end

            private

            def build_metering_record(payload, ctx, props)
              billing = payload[:billing] || {}
              {
                message_id:        props[:message_id],
                correlation_id:    props[:correlation_id],
                conversation_id:   ctx[:conversation_id],
                message_id_ctx:    ctx[:message_id],
                parent_message_id: ctx[:parent_message_id],
                message_seq:       ctx[:message_seq],
                request_id:        ctx[:request_id],
                exchange_id:       ctx[:exchange_id],
                request_type:      payload[:request_type],
                tier:              payload[:tier],
                provider:          payload[:provider],
                model_id:          payload[:model_id],
                node_id:           payload[:node_id],
                worker_id:         payload[:worker_id],
                agent_id:          payload[:agent_id],
                task_id:           payload[:task_id],
                input_tokens:      payload[:input_tokens].to_i,
                output_tokens:     payload[:output_tokens].to_i,
                thinking_tokens:   payload[:thinking_tokens].to_i,
                total_tokens:      payload[:total_tokens].to_i,
                latency_ms:        payload[:latency_ms].to_i,
                wall_clock_ms:     payload[:wall_clock_ms].to_i,
                cost_usd:          payload[:cost_usd].to_f,
                routing_reason:    payload[:routing_reason],
                cost_center:       billing[:cost_center],
                budget_id:         billing[:budget_id],
                recorded_at:       payload[:recorded_at],
                inserted_at:       Time.now.utc
              }
            end
          end
        end
      end
    end
  end
end
