# frozen_string_literal: true

require 'digest'
require 'securerandom'
require 'legion/logging'
require_relative 'stable_identifiers'
require_relative 'json'
require_relative 'persistence_logging'

module Legion
  module Extensions
    module Llm
      module Ledger
        module Helpers
          # Tool persistence: persist llm_tool_calls and llm_tool_call_attempts rows.
          # Handles UUID derivation, retry semantics, response linking, and identity resolution.
          module ToolPersistence
            extend self
            extend Legion::Logging::Helper
            extend StableIdentifiers

            # Write a single tool record to the database.
            # Returns { result: :ok | :duplicate | :error, error: ... }
            def write_tool_record(db, body, headers, ctx, props, tool, response)
              write_result = [:ok]
              db.transaction do
                identity_attrs               = extract_identity_attrs(body, headers, db)
                conversation_id              = resolve_conversation_id(db, body, ctx, headers)
                tool_call_row, new_tool_call = find_or_create_tool_call(db, response, body, ctx, tool, headers,
                                                                        identity_attrs, conversation_id)
                if tool_call_row && !new_tool_call
                  write_result[0] = :duplicate
                elsif new_tool_call
                  find_or_create_tool_call_attempt(db, tool_call_row, tool, body, props, headers, identity_attrs)
                end
              end

              { result: write_result[0] }
            rescue Sequel::UniqueConstraintViolation => e
              log.warn("write_tool_record duplicate insert ignored: #{e.message}")
              { result: :duplicate }
            end

            # Resolve the inference response for a tool record, with retry.
            def find_or_resolve_response_with_retry(db, body, ctx, props, headers)
              response = find_or_resolve_response(db, body, ctx, props, headers)
              return response if response

              retry_attempts = tool_write_setting(:response_retry_attempts, 3)
              retry_delay    = tool_write_setting(:response_retry_delay, 1)

              retry_attempts.times do |attempt|
                sleep retry_delay
                response = find_or_resolve_response(db, body, ctx, props, headers)
                if response
                  log.debug("[ledger] write_tool_record: response found on retry #{attempt + 1}")
                  return response
                end
              end

              log.info('[ledger] write_tool_record: response not available after retries, proceeding with null response_id')
              nil
            end

            private

            def find_or_resolve_response(_db, body, ctx, props, headers)
              request_ref = ctx[:request_id] || body[:request_id] ||
                            props[:correlation_id] || headers['x-legion-llm-request-id']
              return nil unless request_ref

              request = llm_request_model.lookup(request_ref)
              return nil unless request

              llm_response_model.first(message_inference_request_id: request[:id])
            end

            def resolve_conversation_id(_db, body, ctx, headers)
              conv_ref = ctx[:conversation_id] || body[:conversation_id] ||
                         headers['x-legion-llm-conversation-id']
              return nil unless conv_ref

              conv = llm_conversation_model.first(uuid: stable_uuid(conv_ref)) ||
                     llm_conversation_model.first(uuid: conv_ref)
              conv&.[](:id)
            end

            def find_or_create_tool_call(db, response, body, ctx, tool, headers, identity_attrs, conversation_id)
              tool_uuid = derive_tool_call_uuid(body, ctx, tool, headers)
              existing  = llm_tool_call_model.first(uuid: tool_uuid)
              return [existing, false] if existing

              response_id = response&.[](:id)

              next_index = if response_id
                             db[:llm_tool_calls]
                               .where(message_inference_response_id: response_id)
                               .max(:tool_call_index).to_i + 1
                           else
                             0
                           end

              src    = tool[:source] || {}
              status = tool[:status] || headers['x-legion-tool-status'] || 'success'
              ts     = body[:timestamps] || {}

              result_value = tool[:result] || body[:result]
              has_result = tool[:result] || body.key?(:result)
              id = persist_insert(db, :llm_tool_calls, {
                                    uuid:                          tool_uuid,
                                    message_inference_response_id: response_id,
                                    conversation_id:               conversation_id,
                                    tool_call_index:               next_index,
                                    provider_tool_call_ref:        tool[:id],
                                    tool_name:                     tool[:name] || headers['x-legion-tool-name'],
                                    tool_source_type:              src[:type] || headers['x-legion-tool-source-type'],
                                    tool_source_server:            src[:server] || headers['x-legion-tool-source-server'],
                                    status:                        status,
                                    tool_arguments_json:           tool[:arguments] ? Helpers::Json.dump(tool[:arguments]) : nil,
                                    tool_result_json:              has_result ? Helpers::Json.dump(result_value) : nil,
                                    tool_category:                 tool[:category] || tool[:tool_category],
                                    data_handling_classification:  tool[:data_handling_classification],
                                    policy_decision:               tool[:policy_decision],
                                    requires_human_approval:       tool[:requires_human_approval],
                                    requested_at:                  ts[:tool_start] || tool[:started_at],
                                    completed_at:                  ts[:tool_end] || tool[:finished_at],
                                    **identity_attrs,
                                    inserted_at:                   Time.now.utc
                                  }, operation: 'tool_persistence.tool_call')
              [llm_tool_call_model[id], true]
            rescue Sequel::UniqueConstraintViolation
              row = llm_tool_call_model.first(uuid: tool_uuid)
              raise unless row

              [row, false]
            end

            def find_or_create_tool_call_attempt(db, tool_call_row, tool, body, props, headers, identity_attrs)
              return nil unless tool_call_row

              tool_call_id = tool_call_row[:id]
              attempt_no   = db[:llm_tool_call_attempts]
                             .where(tool_call_id: tool_call_id).max(:attempt_no).to_i + 1
              attempt_uuid = derive_attempt_uuid(tool_call_row[:uuid], attempt_no)

              existing = llm_tool_call_attempt_model.first(uuid: attempt_uuid)
              return existing if existing

              status     = tool[:status] || headers['x-legion-tool-status'] || 'success'
              error_info = tool[:error] || body[:error]
              error_hash = error_info.is_a?(Hash) ? error_info : {}
              ts         = body[:timestamps] || {}
              runner_ref = body[:worker_id] || body[:runner_ref] || props[:app_id]

              id = persist_insert(db, :llm_tool_call_attempts, {
                                    uuid:                attempt_uuid,
                                    tool_call_id:        tool_call_id,
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
                                    started_at:          ts[:tool_start] || tool[:started_at],
                                    ended_at:            ts[:tool_end] || tool[:finished_at],
                                    **identity_attrs,
                                    inserted_at:         Time.now.utc
                                  }, operation: 'tool_persistence.attempt')
              llm_tool_call_attempt_model[id]
            rescue Sequel::UniqueConstraintViolation
              llm_tool_call_attempt_model.first(uuid: attempt_uuid) || raise
            end

            def extract_identity_attrs(body, headers, db)
              caller_identity = Helpers::CallerIdentity.normalize(
                caller_raw: body[:caller],
                identity:   body[:identity],
                headers:    headers
              )
              raw_identity   = caller_identity[:identity]
              canonical_name = raw_identity
              # Strip "type:" prefix added by CallerIdentity for generic identities
              if canonical_name&.include?(':') && !canonical_name&.include?('@')
                _prefix, remainder = canonical_name.split(':', 2)
                canonical_name = remainder if remainder && !remainder.empty?
              end

              refs = resolve_tool_identity(db, body, raw_identity)

              {
                identity_canonical_name: canonical_name,
                identity_principal_id:   refs[:principal_id],
                identity_id:             refs[:identity_id]
              }.compact
            end

            def resolve_tool_identity(db, body, raw_identity)
              return {} unless raw_identity
              return {} unless Helpers::IdentityResolution.identity_tables_available?(db)

              body_with_identity = raw_identity ? body.merge(caller_identity: raw_identity) : body
              Helpers::IdentityResolution.resolve_identity(db, body_with_identity)
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

            def persist_insert(db, table, attributes, operation:)
              db.transaction(savepoint: true) do
                Helpers::PersistenceLogging.insert_row(db, table, attributes,
                                                       operation: operation, warn_on_unique: false)
              end
            end

            def tool_write_setting(key, default)
              ledger = Legion::Settings.dig(:extensions, :llm, :ledger) || {}
              tool_write = ledger[:tool_write] || {}
              (tool_write[key] || default).to_i
            end

            def llm_request_model
              ensure_models_loaded!
              ::Legion::Data::Models::LLM::MessageInferenceRequest
            end

            def llm_response_model
              ensure_models_loaded!
              ::Legion::Data::Models::LLM::MessageInferenceResponse
            end

            def llm_conversation_model
              ensure_models_loaded!
              ::Legion::Data::Models::LLM::Conversation
            end

            def llm_tool_call_model
              ensure_models_loaded!
              ::Legion::Data::Models::LLM::ToolCall
            end

            def llm_tool_call_attempt_model
              ensure_models_loaded!
              ::Legion::Data::Models::LLM::ToolCallAttempt
            end

            def ensure_models_loaded!
              require 'legion/data/model' unless defined?(::Legion::Data::Models)
              ::Legion::Data::Models.instance_variable_set(:@loaded_models, []) unless ::Legion::Data::Models.loaded_models

              missing = []
              missing << 'llm/conversation' unless defined?(::Legion::Data::Models::LLM::Conversation)
              missing << 'llm/message_inference_request' unless defined?(::Legion::Data::Models::LLM::MessageInferenceRequest)
              missing << 'llm/message_inference_response' unless defined?(::Legion::Data::Models::LLM::MessageInferenceResponse)
              missing << 'llm/tool_call' unless defined?(::Legion::Data::Models::LLM::ToolCall)
              missing << 'llm/tool_call_attempt' unless defined?(::Legion::Data::Models::LLM::ToolCallAttempt)

              ::Legion::Data::Models.require_sequel_models(missing) unless missing.empty?
            end
          end
        end
      end
    end
  end
end
