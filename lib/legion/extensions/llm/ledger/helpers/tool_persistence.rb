# frozen_string_literal: true

require 'digest'
require 'securerandom'
require 'legion/logging'
require 'legion/data/model'
require_relative 'stable_identifiers'
require_relative 'json'

module Legion
  module Extensions
    module Llm
      module Ledger
        module Helpers
          module ToolPersistence
            extend self
            extend Legion::Logging::Helper
            extend StableIdentifiers

            def write_tool_record(body, headers, ctx, props, tool, response)
              identity_attrs = extract_identity_attrs(body, headers)
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
              handle_exception(e, level: :debug, handled: true, operation: 'tool_persistence.write_tool_record_race')
              { result: :duplicate }
            end

            def find_or_resolve_response_with_retry(body, ctx, props, headers)
              response = find_or_resolve_response(body, ctx, props, headers)
              return response if response

              retry_attempts = tool_write_setting(:response_retry_attempts, 3)
              retry_delay = tool_write_setting(:response_retry_delay, 1)

              retry_attempts.times do |attempt|
                sleep retry_delay
                response = find_or_resolve_response(body, ctx, props, headers)
                if response
                  log.debug("[ledger] write_tool_record: response found on retry #{attempt + 1}")
                  return response
                end
              end

              log.info('[ledger] write_tool_record: response not available after retries, proceeding with null response_id')
              nil
            end

            private

            def find_or_resolve_response(body, ctx, props, headers)
              request_reference = ctx[:request_id] || body[:request_id] ||
                                  props[:correlation_id] || headers['x-legion-llm-request-id']
              return nil unless request_reference

              request = Legion::Data::Models::LLM::MessageInferenceRequest.lookup(request_reference)
              return nil unless request

              request.message_inference_responses_dataset.first
            end

            def resolve_conversation_id(body, ctx, headers)
              conversation_reference = ctx[:conversation_id] || body[:conversation_id] ||
                                       headers['x-legion-llm-conversation-id']
              return nil unless conversation_reference

              conversation = Legion::Data::Models::LLM::Conversation.first(uuid: stable_uuid(conversation_reference)) ||
                             Legion::Data::Models::LLM::Conversation.first(uuid: conversation_reference)
              conversation&.[](:id)
            end

            def find_or_create_tool_call(response:, body:, ctx:, tool:, headers:, identity_attrs:, conversation_id:)
              tool_uuid = derive_tool_call_uuid(body, ctx, tool, headers)
              existing = Legion::Data::Models::LLM::ToolCall.first(uuid: tool_uuid)
              return [existing, false] if existing

              response_id = response&.[](:id)
              next_index = response ? response.tool_calls_dataset.max(:tool_call_index).to_i + 1 : 0
              tool_source = tool[:source] || {}
              status = tool[:status] || headers['x-legion-tool-status'] || 'success'
              timestamps = body[:timestamps] || {}
              result_value = tool[:result] || body[:result]
              has_result = tool[:result] || body.key?(:result)

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
                tool_arguments_json:           tool[:arguments] ? Helpers::Json.dump(tool[:arguments]) : nil,
                tool_result_json:              has_result ? Helpers::Json.dump(result_value) : nil,
                tool_category:                 tool[:category] || tool[:tool_category],
                data_handling_classification:  tool[:data_handling_classification],
                policy_decision:               tool[:policy_decision],
                requires_human_approval:       tool[:requires_human_approval],
                requested_at:                  timestamps[:tool_start] || tool[:started_at],
                completed_at:                  timestamps[:tool_end] || tool[:finished_at],
                **identity_attrs,
                inserted_at:                   Time.now.utc
              )
              log.info("[ledger] tool_persistence.tool_call id=#{record[:id]} uuid=#{tool_uuid}")
              [record, true]
            rescue Sequel::UniqueConstraintViolation => e
              handle_exception(e, level: :debug, handled: true, operation: 'tool_persistence.tool_call_race')
              row = Legion::Data::Models::LLM::ToolCall.first(uuid: tool_uuid)
              raise unless row

              [row, false]
            end

            def find_or_create_tool_call_attempt(tool_call_row:, tool:, body:, props:, headers:, identity_attrs:)
              return nil unless tool_call_row

              attempt_no = tool_call_row.tool_call_attempts_dataset.max(:attempt_no).to_i + 1
              attempt_uuid = derive_attempt_uuid(tool_call_row[:uuid], attempt_no)
              existing = Legion::Data::Models::LLM::ToolCallAttempt.first(uuid: attempt_uuid)
              return existing if existing

              status = tool[:status] || headers['x-legion-tool-status'] || 'success'
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
                attempt_input_json:  tool[:arguments] ? Helpers::Json.dump(tool[:arguments]) : nil,
                attempt_output_json: Helpers::Json.dump(tool[:result] || body[:result]),
                error_details_json:  tool[:error] ? Helpers::Json.dump(tool[:error]) : nil,
                started_at:          timestamps[:tool_start] || tool[:started_at],
                ended_at:            timestamps[:tool_end] || tool[:finished_at],
                **identity_attrs,
                inserted_at:         Time.now.utc
              )
              log.info("[ledger] tool_persistence.attempt id=#{record[:id]}")
              record
            rescue Sequel::UniqueConstraintViolation => e
              handle_exception(e, level: :debug, handled: true, operation: 'tool_persistence.attempt_race')
              Legion::Data::Models::LLM::ToolCallAttempt.first(uuid: attempt_uuid) || raise
            end

            def extract_identity_attrs(body, headers)
              caller_identity = Helpers::CallerIdentity.normalize(
                caller_raw: body[:caller],
                identity:   body[:identity],
                headers:    headers
              )
              raw_identity = caller_identity[:identity]
              canonical_name = raw_identity
              if canonical_name&.include?(':') && !canonical_name&.include?('@')
                _prefix, remainder = canonical_name.split(':', 2)
                canonical_name = remainder if remainder && !remainder.empty?
              end

              refs = resolve_tool_identity(body, raw_identity)

              {
                identity_canonical_name: canonical_name,
                identity_principal_id:   refs[:principal_id],
                identity_id:             refs[:identity_id]
              }.compact
            end

            def resolve_tool_identity(body, raw_identity)
              return {} unless raw_identity
              return {} unless Helpers::IdentityResolution.identity_tables_available?

              Helpers::IdentityResolution.resolve_identity(body.merge(caller_identity: raw_identity))
            rescue StandardError => e
              handle_exception(e, level: :warn, handled: true, operation: 'tool_persistence.identity')
              {}
            end

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

            def sha256_ref(value)
              return nil if value.nil?

              raw = value.is_a?(String) ? value : Helpers::Json.dump(value)
              Digest::SHA256.hexdigest(raw)[0, 64]
            end

            def tool_write_setting(key, default)
              ledger = Legion::Settings.dig(:extensions, :llm, :ledger) || {}
              tool_write = ledger[:tool_write] || {}
              (tool_write[key] || default).to_i
            end
          end
        end
      end
    end
  end
end
