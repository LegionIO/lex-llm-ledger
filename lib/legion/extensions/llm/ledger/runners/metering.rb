# frozen_string_literal: true

require_relative '../helpers/caller_identity'

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
              handle_exception(e, level: :warn, handled: true, operation: 'spool_flush')
              { result: :error, error: e.message }
            end

            def write_metering_record(payload = nil, metadata = {}, **message)
              payload, metadata = normalize_runner_args(payload, metadata, message)
              headers = Helpers::SubscriptionMessage.extract_headers(payload, metadata)
              ctx     = payload[:message_context] || {}
              props   = metadata[:properties] || {}

              Writers::OfficialMeteringWriter.write(official_metering_payload(payload, ctx, props, headers))
            rescue StandardError => e
              handle_exception(e, level: :error, handled: true, operation: 'write_metering_record')
              { result: :error, error: e.message }
            end

            private

            def normalize_runner_args(payload, metadata, message)
              Helpers::SubscriptionMessage.runner_args(payload, metadata, message)
            end

            def build_metering_record(payload, ctx, props, headers)
              billing    = payload[:billing] || {}
              caller_raw = payload[:caller] || {}
              identity   = payload[:identity] || {}
              caller_identity = Helpers::CallerIdentity.normalize(
                caller_raw: caller_raw, identity: identity, headers: headers
              )

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
                caller_identity:   caller_identity[:identity],
                caller_type:       caller_identity[:type],
                recorded_at:       payload[:recorded_at],
                inserted_at:       Time.now.utc
              }
            end

            def resolve_caller_identity(caller, identity, headers)
              Helpers::CallerIdentity.normalize(
                caller_raw: caller, identity: identity, headers: headers
              )[:identity]
            end

            def official_metering_payload(payload, ctx, props, headers)
              identity = Helpers::CallerIdentity.normalize(
                caller_raw: payload[:caller], identity: payload[:identity], headers: headers
              )
              payload.merge(
                message_id:            props[:message_id] || payload[:message_id] || ctx[:message_id],
                correlation_id:        props[:correlation_id] || payload[:correlation_id],
                conversation_id:       ctx[:conversation_id] || payload[:conversation_id],
                request_id:            ctx[:request_id] || payload[:request_id],
                exchange_id:           ctx[:exchange_id] || payload[:exchange_id],
                operation:             payload[:operation] || payload[:request_type] || headers['x-legion-llm-request-type'],
                provider:              payload[:provider] || headers['x-legion-llm-provider'],
                provider_instance:     payload[:provider_instance] || payload[:instance],
                model_id:              payload[:model_id] || headers['x-legion-llm-model'],
                tier:                  payload[:tier] || headers['x-legion-llm-tier'],
                caller_identity:       identity[:identity],
                caller_type:           identity[:type],
                __header_principal_id: identity[:principal_id],
                __header_identity_id:  identity[:identity_id]
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
