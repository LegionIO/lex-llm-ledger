# frozen_string_literal: true

require_relative '../helpers/caller_identity'

module Legion
  module Extensions
    module Llm
      module Ledger
        module Runners
          module Tools
            extend self

            def write_tool_record(payload = nil, metadata = {}, **message)
              payload, metadata = normalize_runner_args(payload, metadata, message)
              headers = Helpers::SubscriptionMessage.extract_headers(payload, metadata)
              props   = metadata[:properties] || {}

              body = payload.is_a?(Hash) ? payload : Helpers::Decryption.decrypt_if_needed(payload, metadata)
              ctx  = body[:message_context] || {}
              tool = body[:tool_call]       || {}

              expires_at = Helpers::Retention.resolve(
                retention:    headers['x-legion-retention'],
                contains_phi: headers['x-legion-contains-phi'] == 'true'
              )

              record = build_tool_record(body, ctx, tool, props, headers, expires_at)
              ::Legion::Data.connection[:llm_tool_records].insert(record)
              { result: :ok }
            rescue Sequel::UniqueConstraintViolation => e
              log.debug("write_tool_record duplicate: #{e.message}")
              { result: :duplicate }
            rescue Helpers::DecryptionUnavailable => e
              log.warn("write_tool_record decryption unavailable: #{e.message}")
              raise
            rescue StandardError => e
              log.error("write_tool_record failed: #{e.message}")
              { result: :error, error: e.message }
            end

            private

            def normalize_runner_args(payload, metadata, message)
              Helpers::SubscriptionMessage.runner_args(payload, metadata, message)
            end

            def build_tool_record(body, ctx, tool, props, headers, expires_at) # rubocop:disable Metrics/AbcSize,Metrics/CyclomaticComplexity,Metrics/PerceivedComplexity
              src      = tool[:source] || {}
              cls      = body[:classification] || {}
              ts       = body[:timestamps] || {}
              tracing    = body[:tracing] || {}
              caller_raw = body[:caller] || {}
              identity   = body[:identity] || {}
              caller_identity = Helpers::CallerIdentity.normalize(
                caller_raw: caller_raw, identity: identity, headers: headers
              )
              agent = body[:agent] || {}

              {
                message_id:           props[:message_id] || body[:message_id],
                correlation_id:       props[:correlation_id] || body[:correlation_id] || tracing[:correlation_id],
                conversation_id:      ctx[:conversation_id] || body[:conversation_id] || headers['x-legion-llm-conversation-id'],
                message_id_ctx:       ctx[:message_id],
                parent_message_id:    ctx[:parent_message_id],
                message_seq:          ctx[:message_seq],
                request_id:           ctx[:request_id] || body[:request_id] || headers['x-legion-llm-request-id'],
                exchange_id:          ctx[:exchange_id] || body[:exchange_id],
                tool_call_id:         tool[:id],
                tool_name:            tool[:name] || headers['x-legion-tool-name'],
                tool_source_type:     src[:type] || headers['x-legion-tool-source-type'],
                tool_source_server:   src[:server] || headers['x-legion-tool-source-server'],
                tool_status:          tool[:status] || headers['x-legion-tool-status'],
                tool_duration_ms:     tool[:duration_ms].to_i,
                arguments_json:       Legion::JSON.dump(tool[:arguments] || {}), # rubocop:disable Legion/HelperMigration/DirectJson
                result_json:          Legion::JSON.dump(tool[:result] || body[:result]), # rubocop:disable Legion/HelperMigration/DirectJson
                error_json:           Legion::JSON.dump(tool[:error] || body[:error]), # rubocop:disable Legion/HelperMigration/DirectJson
                caller_identity:      caller_identity[:identity],
                agent_id:             agent[:id],
                classification_level: cls[:level] || headers['x-legion-classification'],
                contains_phi:         Helpers::Queries.phi_flag?(cls, headers),
                retention_policy:     headers['x-legion-retention'] || 'default',
                expires_at:           expires_at,
                tool_start_at:        ts[:tool_start] || tool[:started_at],
                tool_end_at:          ts[:tool_end] || tool[:finished_at],
                inserted_at:          Time.now.utc
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
