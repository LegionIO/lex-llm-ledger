# frozen_string_literal: true

require 'digest'
require 'securerandom'
require 'legion/logging'
require 'legion/data/model'
require_relative '../helpers/identity_resolution'
require_relative 'conversations'
require_relative 'requests'
require_relative 'responses'

module Legion
  module Extensions
    module Llm
      module Ledger
        module Runners
          # Self-contained tool audit writer.
          # Consumes queue messages from llm.audit.tools and persists:
          #   llm_tool_calls + llm_tool_call_attempts
          module Tools
            extend self
            extend Legion::Logging::Helper

            # ─── Public API ────────────────────────────────────────────────

            def insert(payload: nil, metadata: nil, **message)
              payload, metadata = normalize_insert_args(payload, metadata, message)
              headers = metadata[:headers] || {}
              props   = metadata[:properties] || {}

              body = payload.is_a?(Hash) ? payload : {}
              ctx  = body[:message_context] || {}
              tool = body[:tool_call] || {}

              response = find_or_resolve_response_with_retry(body, ctx, props, headers)
              write_tool_record(body, headers, ctx, props, tool, response)
            rescue Sequel::UniqueConstraintViolation => e
              handle_exception(e, level: :warn, handled: true, operation: 'tools.insert_race')
              { result: :duplicate }
            rescue StandardError => e
              handle_exception(e, level: :error, handled: true, operation: 'tools.insert')
              raise
            end

            private

            # rubocop:disable Legion/Extension/RunnerReturnHash

            # ─── Response Lookup ───────────────────────────────────────────

            def find_or_resolve_response_with_retry(body, ctx, props, headers)
              response = find_or_resolve_response(body, ctx, props, headers)
              return response if response

              retry_attempts = tool_write_setting(:response_retry_attempts, 3)
              retry_delay    = tool_write_setting(:response_retry_delay, 1)

              retry_attempts.times do |attempt|
                sleep retry_delay
                response = find_or_resolve_response(body, ctx, props, headers)
                if response
                  log.debug("[ledger] tools: response found on retry #{attempt + 1}")
                  return response
                end
              end

              log.warn("[ledger] tools: response not available after retries, proceeding with null response_id")
              nil
            end

            def find_or_resolve_response(body, ctx, props, headers)
              request_reference = ctx[:request_id] || body[:request_id] ||
                                  props[:correlation_id] || headers['x-legion-llm-request-id']
              return nil unless request_reference

              request = Legion::Extensions::Llm::Ledger::Runners::Requests.fetch(ref: request_reference)
              return nil unless request

              Legion::Extensions::Llm::Ledger::Runners::Responses.fetch(request_id: request[:id])
            end

            # ─── Tool Record Persistence ───────────────────────────────────

            def write_tool_record(body, headers, ctx, props, tool, response)
              identity_attrs  = resolve_identity_attrs(body, headers)
              conversation_id = resolve_conversation_id(body, ctx, headers)

              tool_call_row, new_tool_call = find_or_create_tool_call(
                response:        response,
                body:            body,
                ctx:             ctx,
                tool:            tool,
                headers:         headers,
                identity_attrs:  identity_attrs,
                conversation_id: conversation_id
              )

              if tool_call_row && !new_tool_call
                { result: :duplicate }
              else
                find_or_create_tool_call_attempt(
                  tool_call_row:  tool_call_row,
                  tool:           tool,
                  body:           body,
                  props:          props,
                  headers:        headers,
                  identity_attrs: identity_attrs
                )
                { result: :ok }
              end
            rescue Sequel::UniqueConstraintViolation => e
              handle_exception(e, level: :warn, handled: true, operation: 'tools.write_tool_record_race')
              { result: :duplicate }
            end

            def find_or_create_tool_call(response:, body:, ctx:, tool:, headers:, identity_attrs:, conversation_id:)
              tool_uuid = derive_tool_call_uuid(body, ctx, tool, headers)
              existing  = Legion::Data::Models::LLM::ToolCall.first(uuid: tool_uuid)
              return [existing, false] if existing

              response_id = response&.[](:id)
              next_index  = response ? Legion::Data::Models::LLM::ToolCall.where(message_inference_response_id: response[:id]).max(:tool_call_index).to_i + 1 : 0
              tool_source = tool[:source] || {}
              status      = tool[:status] || headers['x-legion-tool-status'] || 'success'
              timestamps  = body[:timestamps] || {}
              result_value = tool[:result] || body[:result]
              has_result   = tool.key?(:result) || body.key?(:result)

              record = Legion::Data::Models::LLM::ToolCall.create(
                uuid:                          tool_uuid,
                message_inference_response_id: response_id,
                conversation_id:               conversation_id,
                tool_call_index:               next_index,
                provider_tool_call_ref:        tool[:id],
                tool_name:                     tool[:name] || headers['x-legion-tool-name'],
                tool_source_type:              tool_source[:type] || headers['x-legion-tool-source-type'],
                tool_source_server:            tool_source[:server] || headers['x-legion-tool-source-server'],
                status:                        status,
                tool_arguments_json:           tool[:arguments] ? Legion::JSON.dump(tool[:arguments]) : nil, # rubocop:disable Legion/HelperMigration/DirectJson
                tool_result_json:              has_result ? Legion::JSON.dump(result_value) : nil, # rubocop:disable Legion/HelperMigration/DirectJson
                tool_category:                 tool[:category] || tool[:tool_category],
                data_handling_classification:  tool[:data_handling_classification],
                policy_decision:               tool[:policy_decision],
                requires_human_approval:       tool[:requires_human_approval],
                requested_at:                  timestamps[:tool_start] || tool[:started_at],
                completed_at:                  timestamps[:tool_end] || tool[:finished_at],
                **identity_attrs,
                inserted_at:                   Time.now.utc
              )
              log.info("[ledger] tools.tool_call id=#{record[:id]} uuid=#{tool_uuid}")
              [record, true]
            rescue Sequel::UniqueConstraintViolation => e
              handle_exception(e, level: :warn, handled: true, operation: 'tools.tool_call_race')
              row = Legion::Data::Models::LLM::ToolCall.first(uuid: tool_uuid)
              raise unless row

              [row, false]
            end

            def find_or_create_tool_call_attempt(tool_call_row:, tool:, body:, props:, headers:, identity_attrs:)
              return nil unless tool_call_row

              attempt_no   = tool_call_row.tool_call_attempts_dataset.max(:attempt_no).to_i + 1
              attempt_uuid = derive_attempt_uuid(tool_call_row[:uuid], attempt_no)
              existing     = Legion::Data::Models::LLM::ToolCallAttempt.first(uuid: attempt_uuid)
              return existing if existing

              status     = tool[:status] || headers['x-legion-tool-status'] || 'success'
              error_info = tool[:error] || body[:error]
              error_hash = error_info.is_a?(Hash) ? error_info : {}
              timestamps = body[:timestamps] || {}
              runner_ref = body[:worker_id] || body[:runner_ref] || props[:app_id]

              record = Legion::Data::Models::LLM::ToolCallAttempt.create(
                uuid:                attempt_uuid,
                tool_call_id:        tool_call_row[:id],
                attempt_no:          attempt_no,
                runner_ref:          runner_ref,
                status:              status,
                error_category:      error_hash[:category] || error_hash[:type],
                error_code:          error_hash[:code],
                error_message:       error_info.is_a?(String) ? error_info : error_hash[:message],
                duration_ms:         tool[:duration_ms].to_i,
                arguments_ref:       sha256_ref(tool[:arguments]),
                result_ref:          sha256_ref(tool[:result] || body[:result]),
                attempt_input_json:  tool[:arguments] ? Legion::JSON.dump(tool[:arguments]) : nil, # rubocop:disable Legion/HelperMigration/DirectJson
                attempt_output_json: Legion::JSON.dump(tool[:result] || body[:result]), # rubocop:disable Legion/HelperMigration/DirectJson
                error_details_json:  tool[:error] ? Legion::JSON.dump(tool[:error]) : nil, # rubocop:disable Legion/HelperMigration/DirectJson
                started_at:          timestamps[:tool_start] || tool[:started_at],
                ended_at:            timestamps[:tool_end] || tool[:finished_at],
                **identity_attrs,
                inserted_at:         Time.now.utc
              )
              log.info("[ledger] tools.attempt id=#{record[:id]}")
              record
            rescue Sequel::UniqueConstraintViolation => e
              handle_exception(e, level: :warn, handled: true, operation: 'tools.attempt_race')
              Legion::Data::Models::LLM::ToolCallAttempt.first(uuid: attempt_uuid) || raise
            end

            # ─── Identity ──────────────────────────────────────────────────

            def resolve_identity_attrs(body, headers)
              refs = Legion::Extensions::Llm::Ledger::Helpers::IdentityResolution.resolve_refs(body: body, headers: headers)
              canonical = refs[:canonical_name]

              {
                identity_canonical_name: canonical,
                identity_principal_id:   refs[:principal_id],
                identity_id:             refs[:identity_id]
              }.compact
            end

            def resolve_conversation_id(body, ctx, headers)
              conversation_reference = ctx[:conversation_id] || body[:conversation_id] ||
                                       headers['x-legion-llm-conversation-id']
              return nil unless conversation_reference

              conversation = Legion::Extensions::Llm::Ledger::Runners::Conversations.fetch(ref: conversation_reference)
              conversation&.[](:id)
            end

            # ─── UUID Derivation ───────────────────────────────────────────

            def derive_tool_call_uuid(body, ctx, tool, headers)
              ref = tool[:id] ||
                    ctx[:request_id] ||
                    body[:request_id] ||
                    headers['x-legion-llm-request-id'] ||
                    ctx[:message_id] ||
                    (body[:properties] || {})[:message_id]
              stable_uuid("tool_call:#{ref || SecureRandom.uuid}")
            end

            def derive_attempt_uuid(tool_call_uuid, attempt_no)
              stable_uuid("attempt:#{tool_call_uuid}:#{attempt_no}")
            end

            def stable_uuid(value)
              raw = value.to_s
              return raw if raw.length <= 36

              hex = Digest::SHA256.hexdigest(raw)[0, 32]
              "#{hex[0, 8]}-#{hex[8, 4]}-#{hex[12, 4]}-#{hex[16, 4]}-#{hex[20, 12]}"
            end

            def sha256_ref(value)
              return nil if value.nil?

              raw = value.is_a?(String) ? value : Legion::JSON.dump(value) # rubocop:disable Legion/HelperMigration/DirectJson
              Digest::SHA256.hexdigest(raw)[0, 64]
            end

            # ─── Settings ──────────────────────────────────────────────────

            def tool_write_setting(key, default)
              ledger     = Legion::Settings.dig(:extensions, :llm, :ledger) || {}
              tool_write = ledger[:tool_write] || {}
              (tool_write[key] || default).to_i
            end

            # rubocop:enable Legion/Extension/RunnerReturnHash

            def normalize_insert_args(payload, metadata, message)
              if payload
                [payload, metadata || {}]
              else
                headers = message.each_with_object({}) { |(k, v), h| h[k.to_s] = v if k.to_s.start_with?('x-legion-') }
                [message, { headers: headers, properties: { message_id: message[:message_id], correlation_id: message[:correlation_id] } }]
              end
            end

            include Legion::Extensions::Helpers::Lex if Legion::Extensions.const_defined?(:Helpers, false) &&
                                                        Legion::Extensions::Helpers.const_defined?(:Lex, false)
          end
        end
      end
    end
  end
end
