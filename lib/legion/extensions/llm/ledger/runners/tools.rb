# frozen_string_literal: true

module Legion
  module Extensions
    module Llm
      module Ledger
        module Runners
          module Tools
            extend self

            def write_tool_record(payload, metadata = {})
              headers = metadata[:headers] || {}
              props   = metadata[:properties] || {}

              body = Helpers::Decryption.decrypt_if_needed(payload, metadata)
              ctx  = body[:message_context] || {}
              tool = body[:tool_call]       || {}

              expires_at = Helpers::Retention.resolve(
                retention:    headers['x-legion-retention'],
                contains_phi: headers['x-legion-contains-phi'] == 'true'
              )

              record = build_tool_record(body, ctx, tool, props, headers, expires_at)
              ::Legion::Data::DB[:tool_records].insert(record)
              { result: :ok }
            rescue Sequel::UniqueConstraintViolation => _e
              { result: :duplicate }
            rescue Helpers::DecryptionUnavailable => _e
              raise
            rescue StandardError => e
              Legion::Logging.error("[lex-llm-ledger] write_tool_record failed: #{e.message}") # rubocop:disable Legion/HelperMigration/DirectLogging
              { result: :error, error: e.message }
            end

            private

            def build_tool_record(body, ctx, tool, props, headers, expires_at)
              src    = tool[:source] || {}
              cls    = body[:classification] || {}
              ts     = body[:timestamps] || {}
              caller = body.dig(:caller, :requested_by) || {}
              agent  = body[:agent] || {}

              {
                message_id:           props[:message_id],
                correlation_id:       props[:correlation_id],
                conversation_id:      ctx[:conversation_id],
                message_id_ctx:       ctx[:message_id],
                parent_message_id:    ctx[:parent_message_id],
                message_seq:          ctx[:message_seq],
                request_id:           ctx[:request_id],
                exchange_id:          ctx[:exchange_id],
                tool_call_id:         tool[:id],
                tool_name:            tool[:name] || headers['x-legion-tool-name'],
                tool_source_type:     src[:type] || headers['x-legion-tool-source-type'],
                tool_source_server:   src[:server] || headers['x-legion-tool-source-server'],
                tool_status:          tool[:status] || headers['x-legion-tool-status'],
                tool_duration_ms:     tool[:duration_ms].to_i,
                arguments_json:       Legion::JSON.dump(tool[:arguments] || {}), # rubocop:disable Legion/HelperMigration/DirectJson
                result_json:          Legion::JSON.dump(tool[:result]), # rubocop:disable Legion/HelperMigration/DirectJson
                error_json:           Legion::JSON.dump(tool[:error]), # rubocop:disable Legion/HelperMigration/DirectJson
                caller_identity:      caller[:identity],
                agent_id:             agent[:id],
                classification_level: cls[:level] || headers['x-legion-classification'],
                contains_phi:         Helpers::Queries.phi_flag?(cls, headers),
                retention_policy:     headers['x-legion-retention'] || 'default',
                expires_at:           expires_at,
                tool_start_at:        ts[:tool_start],
                tool_end_at:          ts[:tool_end],
                inserted_at:          Time.now.utc
              }
            end
          end
        end
      end
    end
  end
end
