# frozen_string_literal: true

module Legion
  module Extensions
    module Llm
      module Ledger
        module Runners
          module Prompts
            extend self

            def write_prompt_record(payload, metadata = {})
              headers = metadata[:headers] || {}
              props   = metadata[:properties] || {}

              body = Helpers::Decryption.decrypt_if_needed(payload, metadata)
              ctx  = body[:message_context] || {}

              expires_at = Helpers::Retention.resolve(
                retention:    headers['x-legion-retention'],
                contains_phi: headers['x-legion-contains-phi'] == 'true'
              )

              record = build_prompt_record(body, ctx, props, headers, expires_at)
              ::Legion::Data::DB[:prompt_records].insert(record)
              { result: :ok }
            rescue Sequel::UniqueConstraintViolation => _e
              { result: :duplicate }
            rescue Helpers::DecryptionUnavailable => _e
              raise
            rescue StandardError => e
              Legion::Logging.error("[lex-llm-ledger] write_prompt_record failed: #{e.message}") # rubocop:disable Legion/HelperMigration/DirectLogging
              { result: :error, error: e.message }
            end

            private

            def build_prompt_record(body, ctx, props, headers, expires_at)
              routing = body[:routing] || {}
              tokens  = body[:tokens]  || {}
              cost    = body[:cost]    || {}
              caller  = body.dig(:caller, :requested_by) || {}
              agent   = body[:agent] || {}
              cls     = body[:classification] || {}
              quality = body[:quality] || {}
              ts      = body[:timestamps] || {}

              {
                message_id:           props[:message_id],
                correlation_id:       props[:correlation_id],
                conversation_id:      ctx[:conversation_id],
                message_id_ctx:       ctx[:message_id],
                parent_message_id:    ctx[:parent_message_id],
                message_seq:          ctx[:message_seq],
                request_id:           ctx[:request_id],
                exchange_id:          ctx[:exchange_id],
                response_message_id:  body[:response_message_id],
                provider:             routing[:provider],
                model_id:             routing[:model],
                tier:                 routing[:tier],
                request_type:         headers['x-legion-llm-request-type'],
                request_json:         Legion::JSON.dump(body[:request] || {}), # rubocop:disable Legion/HelperMigration/DirectJson
                response_json:        Legion::JSON.dump(body[:response] || {}), # rubocop:disable Legion/HelperMigration/DirectJson
                input_tokens:         tokens[:input].to_i,
                output_tokens:        tokens[:output].to_i,
                total_tokens:         tokens[:total].to_i,
                cost_usd:             cost[:estimated_usd].to_f,
                caller_identity:      caller[:identity],
                caller_type:          caller[:type],
                agent_id:             agent[:id],
                task_id:              agent[:task_id],
                classification_level: cls[:level] || headers['x-legion-classification'],
                contains_phi:         Helpers::Queries.phi_flag?(cls, headers),
                contains_pii:         cls[:contains_pii] ? true : false,
                jurisdictions:        Array(cls[:jurisdictions]).join(','),
                quality_score:        quality[:score],
                quality_band:         quality[:band],
                retention_policy:     headers['x-legion-retention'] || 'default',
                expires_at:           expires_at,
                recorded_at:          ts[:returned] || ts[:provider_end],
                inserted_at:          Time.now.utc
              }
            end
          end
        end
      end
    end
  end
end
