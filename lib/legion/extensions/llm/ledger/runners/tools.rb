# frozen_string_literal: true

require 'digest'
require 'securerandom'
require_relative '../helpers/caller_identity'
require_relative '../helpers/json'
require_relative '../helpers/persistence_logging'

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

              db = ::Legion::Data.connection
              response = find_or_resolve_response_with_retry(db, body, ctx, props, headers)
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
            rescue Helpers::DecryptionUnavailable => e
              handle_exception(e, level: :warn, handled: true, operation: 'write_tool_record.decrypt')
              raise
            rescue Helpers::DecryptionFailed => e
              handle_exception(e, level: :error, handled: true, operation: 'write_tool_record.decrypt')
              raise
            rescue StandardError => e
              handle_exception(e, level: :error, handled: true, operation: 'write_tool_record')
              { result: :error, error: e.message }
            end

            private

            def normalize_runner_args(payload, metadata, message)
              Helpers::SubscriptionMessage.runner_args(payload, metadata, message)
            end

            def find_or_resolve_response_with_retry(db, body, ctx, props, headers)
              response = find_or_resolve_response(db, body, ctx, props, headers)
              return response if response # rubocop:disable Legion/Extension/RunnerReturnHash

              retry_attempts = tool_write_setting(:response_retry_attempts, 3)
              retry_delay    = tool_write_setting(:response_retry_delay, 1)

              retry_attempts.times do |attempt|
                sleep retry_delay
                response = find_or_resolve_response(db, body, ctx, props, headers)
                if response
                  log.debug("[ledger] write_tool_record: response found on retry #{attempt + 1}")
                  return response # rubocop:disable Legion/Extension/RunnerReturnHash
                end
              end

              log.info('[ledger] write_tool_record: response not available after retries, proceeding with null response_id')
              nil
            end

            def find_or_resolve_response(db, body, ctx, props, headers)
              request_ref = ctx[:request_id] || body[:request_id] ||
                            props[:correlation_id] || headers['x-legion-llm-request-id']
              return nil unless request_ref # rubocop:disable Legion/Extension/RunnerReturnHash

              request = db[:llm_message_inference_requests].where(request_ref: request_ref).first
              return nil unless request # rubocop:disable Legion/Extension/RunnerReturnHash

              db[:llm_message_inference_responses]
                .where(message_inference_request_id: request[:id]).first
            end

            def resolve_conversation_id(db, body, ctx, headers)
              conv_ref = ctx[:conversation_id] || body[:conversation_id] ||
                         headers['x-legion-llm-conversation-id']
              return nil unless conv_ref # rubocop:disable Legion/Extension/RunnerReturnHash

              conv = db[:llm_conversations].where(uuid: stable_uuid(conv_ref)).first ||
                     db[:llm_conversations].where(uuid: conv_ref).first
              conv&.[](:id)
            end

            def find_or_create_tool_call(db, response, body, ctx, tool, headers, identity_attrs, conversation_id) # rubocop:disable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
              tool_uuid = derive_tool_call_uuid(body, ctx, tool, headers)
              existing  = db[:llm_tool_calls].where(uuid: tool_uuid).first
              return [existing, false] if existing # rubocop:disable Legion/Extension/RunnerReturnHash

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
              id = insert_with_savepoint(db, :llm_tool_calls, {
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
                                         }, operation: 'write_tool_record.tool_call')
              [db[:llm_tool_calls][id: id], true]
            rescue Sequel::UniqueConstraintViolation => e
              log.debug("[ledger] tool_call collision resolved uuid=#{tool_uuid} error=#{e.class}")
              row = db[:llm_tool_calls].where(uuid: tool_uuid).first
              raise(e) unless row

              [row, false]
            end

            def find_or_create_tool_call_attempt(db, tool_call_row, tool, body, props, headers, identity_attrs) # rubocop:disable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity, Metrics/AbcSize
              return nil unless tool_call_row # rubocop:disable Legion/Extension/RunnerReturnHash

              tool_call_id = tool_call_row[:id]
              attempt_no   = db[:llm_tool_call_attempts]
                             .where(tool_call_id: tool_call_id).max(:attempt_no).to_i + 1
              attempt_uuid = derive_attempt_uuid(tool_call_row[:uuid], attempt_no)

              existing = db[:llm_tool_call_attempts].where(uuid: attempt_uuid).first
              return existing if existing # rubocop:disable Legion/Extension/RunnerReturnHash

              status     = tool[:status] || headers['x-legion-tool-status'] || 'success'
              error_info = tool[:error] || body[:error]
              error_hash = error_info.is_a?(Hash) ? error_info : {}
              ts         = body[:timestamps] || {}
              runner_ref = body[:worker_id] || body[:runner_ref] || props[:app_id]

              id = insert_with_savepoint(db, :llm_tool_call_attempts, {
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
                                         }, operation: 'write_tool_record.attempt')
              db[:llm_tool_call_attempts][id: id]
            rescue Sequel::UniqueConstraintViolation => e
              log.debug("[ledger] tool_call_attempt collision resolved uuid=#{attempt_uuid} error=#{e.class}")
              db[:llm_tool_call_attempts].where(uuid: attempt_uuid).first || raise(e)
            end

            def extract_identity_attrs(body, headers, db)
              caller_identity = Helpers::CallerIdentity.normalize(
                caller_raw: body[:caller],
                identity:   body[:identity],
                headers:    headers
              )
              # raw_identity may carry a "type:value" prefix that OfficialRecordWriter
              # knows how to parse; keep it intact for FK resolution.
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
              return {} unless Writers::OfficialRecordWriter.identity_tables_available?(db)

              # Merge the header-resolved identity string into the body so that
              # OfficialRecordWriter.resolve_identity can find it via
              # parsed_identity_descriptor even when identity came solely from
              # AMQP headers and is absent from the payload body.
              body_with_identity = raw_identity ? body.merge(caller_identity: raw_identity) : body
              Writers::OfficialRecordWriter.resolve_identity(db, body_with_identity)
            rescue StandardError => e
              handle_exception(e, level: :warn, handled: true, operation: 'write_tool_record.identity_resolution')
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
              return nil if value.nil? # rubocop:disable Legion/Extension/RunnerReturnHash

              raw = value.is_a?(String) ? value : Helpers::Json.dump(value)
              Digest::SHA256.hexdigest(raw)[0, 64]
            end

            def stable_uuid(value)
              raw = value.to_s
              return raw if raw.length <= 36 # rubocop:disable Legion/Extension/RunnerReturnHash

              hex = Digest::SHA256.hexdigest(raw)[0, 32]
              "#{hex[0, 8]}-#{hex[8, 4]}-#{hex[12, 4]}-#{hex[16, 4]}-#{hex[20, 12]}"
            end

            def tool_write_setting(key, default)
              ledger = Legion::Settings.dig(:extensions, :llm, :ledger) || {}
              tool_write = ledger[:tool_write] || {}
              (tool_write[key] || default).to_i
            end

            def insert_with_savepoint(db, table, attributes, operation:)
              db.transaction(savepoint: true) do
                Helpers::PersistenceLogging.insert_row(db, table, attributes,
                                                       operation: operation, warn_on_unique: false)
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
