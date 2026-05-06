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
              log.warn("spool_flush failed: #{e.message}")
              { result: :error, error: e.message }
            end

            def write_metering_record(payload = nil, metadata = {}, **message)
              log.unknown "write_metering_record => #{metadata}, payload: #{payload}, message: #{message}"
              payload, metadata = normalize_runner_args(payload, metadata, message)
              headers = Helpers::SubscriptionMessage.extract_headers(payload, metadata)
              ctx     = payload[:message_context] || {}
              props   = metadata[:properties] || {}

              Writers::OfficialMeteringWriter.write(official_metering_payload(payload, ctx, props, headers))
            rescue StandardError => e
              log.error("write_metering_record failed: #{e.message}")
              { result: :error, error: e.message }
            end

            private

            def normalize_runner_args(payload, metadata, message)
              Helpers::SubscriptionMessage.runner_args(payload, metadata, message)
            end

            def build_metering_record(payload, ctx, props, headers) # rubocop:disable Metrics/CyclomaticComplexity
              billing    = payload[:billing] || {}
              caller_raw = payload[:caller] || {}
              caller     = caller_raw[:requested_by] || caller_raw
              identity   = payload[:identity] || {}

              {
                message_id:        props[:message_id] || payload[:message_id],
                correlation_id:    props[:correlation_id] || payload[:correlation_id],
                conversation_id:   ctx[:conversation_id] || payload[:conversation_id],
                message_id_ctx:    ctx[:message_id],
                parent_message_id: ctx[:parent_message_id],
                message_seq:       ctx[:message_seq],
                request_id:        ctx[:request_id] || payload[:request_id],
                exchange_id:       ctx[:exchange_id],
                request_type:      payload[:request_type] || headers['x-legion-llm-request-type'],
                tier:              payload[:tier]     || headers['x-legion-llm-tier'],
                provider:          payload[:provider] || headers['x-legion-llm-provider'],
                model_id:          payload[:model_id] || headers['x-legion-llm-model'],
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
                caller_identity:   resolve_caller_identity(caller, identity, headers),
                caller_type:       caller[:type] || identity[:type] || headers['x-legion-caller-type'] || (caller[:extension] && 'extension'),
                recorded_at:       payload[:recorded_at],
                inserted_at:       Time.now.utc
              }
            end

            def resolve_caller_identity(caller, identity, headers)
              caller[:identity] || identity[:identity] || headers['x-legion-caller-identity'] ||
                (caller[:extension] && "extension:#{caller[:extension]}")
            end

            def official_metering_payload(payload, ctx, props, headers)
              payload.merge(
                message_id:        props[:message_id] || payload[:message_id] || ctx[:message_id],
                correlation_id:    props[:correlation_id] || payload[:correlation_id],
                conversation_id:   ctx[:conversation_id] || payload[:conversation_id],
                request_id:        ctx[:request_id] || payload[:request_id],
                exchange_id:       ctx[:exchange_id] || payload[:exchange_id],
                operation:         payload[:operation] || payload[:request_type] || headers['x-legion-llm-request-type'],
                provider:          payload[:provider] || headers['x-legion-llm-provider'],
                provider_instance: payload[:provider_instance] || payload[:instance],
                model_id:          payload[:model_id] || headers['x-legion-llm-model'],
                tier:              payload[:tier] || headers['x-legion-llm-tier']
              )
            end

            include Legion::Extensions::Helpers::Lex if Legion::Extensions.const_defined?(:Helpers, false) &&
                                                        Legion::Extensions::Helpers.const_defined?(:Lex, false)
          end
        end
      end
    end
  end
end
