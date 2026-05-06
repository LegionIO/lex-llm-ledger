# frozen_string_literal: true

require_relative '../helpers/caller_identity'

module Legion
  module Extensions
    module Llm
      module Ledger
        module Runners
          module Prompts
            extend self

            def write_prompt_record(payload = nil, metadata = {}, **message)
              log.unknown "write_prompt_record => #{metadata}, payload: #{payload}, message: #{message.except(:system_prompt, :messages)}"
              payload, metadata = normalize_runner_args(payload, metadata, message)
              headers = Helpers::SubscriptionMessage.extract_headers(payload, metadata)
              props   = metadata[:properties] || {}

              body = payload.is_a?(Hash) ? payload : Helpers::Decryption.decrypt_if_needed(payload, metadata)
              ctx  = body[:message_context] || {}

              expires_at = Helpers::Retention.resolve(
                retention:    headers['x-legion-retention'],
                contains_phi: headers['x-legion-contains-phi'] == 'true'
              )

              Writers::OfficialPromptWriter.write(official_prompt_payload(body, ctx, props, headers, expires_at))
            rescue Helpers::DecryptionUnavailable => e
              log.warn("write_prompt_record decryption unavailable: #{e.message}")
              raise
            rescue StandardError => e
              log.error("write_prompt_record failed: #{e.message}")
              { result: :error, error: e.message }
            end

            private

            def normalize_runner_args(payload, metadata, message)
              Helpers::SubscriptionMessage.runner_args(payload, metadata, message)
            end

            def build_prompt_record(body, ctx, props, headers, expires_at) # rubocop:disable Metrics/AbcSize,Metrics/CyclomaticComplexity,Metrics/PerceivedComplexity
              routing = body[:routing] || {}
              tokens  = body[:tokens]  || {}
              cost    = body[:cost]    || {}
              caller_raw = body[:caller] || {}
              identity   = body[:identity] || {}
              caller_identity = Helpers::CallerIdentity.normalize(
                caller_raw: caller_raw, identity: identity, headers: headers
              )
              agent = body[:agent] || {}
              cls     = body[:classification] || {}
              quality = body[:quality] || {}
              ts      = body[:timestamps] || {}
              tracing = body[:tracing] || {}

              {
                message_id:             props[:message_id] || body[:message_id],
                correlation_id:         props[:correlation_id] || body[:correlation_id] || tracing[:correlation_id],
                conversation_id:        ctx[:conversation_id] || body[:conversation_id] || headers['x-legion-llm-conversation-id'],
                message_id_ctx:         ctx[:message_id],
                parent_message_id:      ctx[:parent_message_id],
                message_seq:            ctx[:message_seq],
                request_id:             ctx[:request_id] || body[:request_id] || headers['x-legion-llm-request-id'],
                exchange_id:            ctx[:exchange_id] || body[:exchange_id],
                response_message_id:    body[:response_message_id],
                provider:               routing[:provider] || body[:provider] || headers['x-legion-llm-provider'],
                model_id:               routing[:model] || body[:model_id] || headers['x-legion-llm-model'],
                tier:                   routing[:tier] || body[:tier] || headers['x-legion-llm-tier'],
                request_type:           body[:request_type] || headers['x-legion-llm-request-type'],
                request_json:           Legion::JSON.dump(body[:request] || body[:messages] || {}), # rubocop:disable Legion/HelperMigration/DirectJson
                response_json:          Legion::JSON.dump(body[:response] || body[:response_content] || {}), # rubocop:disable Legion/HelperMigration/DirectJson
                response_thinking_json: Legion::JSON.dump(response_thinking(body)), # rubocop:disable Legion/HelperMigration/DirectJson
                input_tokens:           (tokens[:input] || tokens[:input_tokens]).to_i,
                output_tokens:          (tokens[:output] || tokens[:output_tokens]).to_i,
                total_tokens:           (tokens[:total] || tokens[:total_tokens]).to_i,
                cost_usd:               cost[:estimated_usd].to_f,
                caller_identity:        caller_identity[:identity],
                caller_type:            caller_identity[:type],
                agent_id:               agent[:id],
                task_id:                agent[:task_id],
                classification_level:   cls[:level] || headers['x-legion-classification'],
                contains_phi:           Helpers::Queries.phi_flag?(cls, headers),
                contains_pii:           cls[:contains_pii] ? true : false,
                jurisdictions:          Array(cls[:jurisdictions]).join(','),
                quality_score:          quality[:score],
                quality_band:           quality[:band],
                retention_policy:       headers['x-legion-retention'] || 'default',
                expires_at:             expires_at,
                recorded_at:            ts[:returned] || ts[:provider_end] || body[:timestamp],
                inserted_at:            Time.now.utc
              }
            end

            def response_thinking(body)
              body[:response_thinking] || body[:thinking] || body.dig(:response, :thinking) || {}
            end

            def official_prompt_payload(body, ctx, props, headers, expires_at)
              body.merge(
                official_context_payload(body, ctx, props, headers),
                official_identity_payload(body, headers),
                official_routing_payload(body, headers),
                official_compliance_payload(body, headers, expires_at)
              )
            end

            def official_identity_payload(body, headers)
              identity = Helpers::CallerIdentity.normalize(
                caller_raw: body[:caller], identity: body[:identity], headers: headers
              )
              {
                caller_identity: identity[:identity],
                caller_type:     identity[:type]
              }.compact
            end

            def official_context_payload(body, ctx, props, headers)
              {
                message_id:          props[:message_id] || body[:message_id] || ctx[:message_id],
                correlation_id:      props[:correlation_id] || body[:correlation_id],
                conversation_id:     ctx[:conversation_id] || body[:conversation_id] || headers['x-legion-llm-conversation-id'],
                response_message_id: body[:response_message_id],
                request_id:          ctx[:request_id] || body[:request_id] || headers['x-legion-llm-request-id'],
                exchange_id:         ctx[:exchange_id] || body[:exchange_id]
              }
            end

            def official_routing_payload(body, headers)
              routing = body[:routing] || {}
              {
                operation:         body[:operation] || body[:request_type] || headers['x-legion-llm-request-type'],
                provider:          routing[:provider] || body[:provider] || headers['x-legion-llm-provider'],
                provider_instance: routing[:provider_instance] || routing[:instance] || body[:provider_instance],
                model_id:          routing[:model] || body[:model_id] || headers['x-legion-llm-model'],
                tier:              routing[:tier] || body[:tier] || headers['x-legion-llm-tier']
              }
            end

            def official_compliance_payload(body, headers, expires_at)
              {
                retention_policy:     headers['x-legion-retention'] || body[:retention_policy],
                expires_at:           expires_at,
                contains_phi:         headers['x-legion-contains-phi'] == 'true' || body.dig(:classification, :contains_phi),
                classification_level: body.dig(:classification, :level) || headers['x-legion-classification']
              }
            end

            include Legion::Extensions::Helpers::Lex if Legion::Extensions.const_defined?(:Helpers, false) &&
                                                        Legion::Extensions::Helpers.const_defined?(:Lex, false)
          end
        end
      end
    end
  end
end
