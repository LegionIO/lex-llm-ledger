# frozen_string_literal: true

require 'digest'
require_relative '../helpers/json'
require_relative '../helpers/persistence_logging'

module Legion
  module Extensions
    module Llm
      module Ledger
        module Writers
          module OfficialRouteAttemptWriter
            extend Legion::Logging::Helper

            module_function

            # Persist route attempt details into llm_route_attempts table.
            # Called from write_prompt/write_metering after the response row exists.
            #
            # Maps emitter keys to table columns:
            #   provider        -> provider
            #   instance        -> route_target
            #   model           -> model_key
            #   operation       -> operation
            #   dispatch_path   -> dispatch_path
            #   status          -> status
            #   failure_reason  -> failure_reason
            #   idempotency_key -> idempotency_key
            def write_route_attempts(db, request, response, body)
              attempts = Array(body[:route_attempt_details])
              return if attempts.empty?

              attempts.each_with_index do |attempt, idx|
                next unless attempt.is_a?(Hash)

                attempt_no = (attempt[:attempt_no] || (idx + 1)).to_i
                uuid = stable_uuid("#{request[:uuid]}:attempt:#{attempt_no}")

                existing = db[:llm_route_attempts].where(uuid: uuid).first
                next if existing

                begin
                  Helpers::PersistenceLogging.insert_row(
                    db,
                    :llm_route_attempts,
                    {
                      uuid:                          uuid,
                      message_inference_request_id:  request[:id],
                      message_inference_response_id: response[:id],
                      attempt_no:                    attempt_no,
                      provider:                      attempt[:provider] || body[:provider],
                      model_key:                     attempt[:model] || attempt[:model_key] || body[:model_id],
                      tier:                          attempt[:tier] || body[:tier],
                      route_target:                  attempt[:route_target] || attempt[:instance],
                      status:                        (attempt[:status] || 'success').to_s,
                      failure_reason:                attempt[:failure_reason],
                      latency_ms:                    (attempt[:latency_ms] || 0).to_i,
                      operation:                     attempt[:operation],
                      dispatch_path:                 attempt[:dispatch_path],
                      idempotency_key:               attempt[:idempotency_key],
                      started_at:                    attempt[:started_at],
                      ended_at:                      attempt[:ended_at],
                      identity_principal_id:         resolve_identity_principal_id(db, body),
                      identity_id:                   resolve_identity_id(db, body),
                      identity_canonical_name:       identity_canonical_name(body),
                      inserted_at:                   Time.now.utc
                    },
                    operation: 'official_route_attempt_writer.insert'
                  )
                rescue Sequel::UniqueConstraintViolation => e
                  log.debug("[ledger] route_attempt collision resolved uuid=#{uuid} error=#{e.class}")
                end
              end
            end

            def resolve_identity_principal_id(db, body)
              Helpers::CallerIdentity.resolve_principal_id(db, body)
            rescue StandardError => e
              handle_exception(e, level: :warn, handled: true, operation: 'route_attempt_writer.identity_principal')
              nil
            end

            def resolve_identity_id(db, body)
              Helpers::CallerIdentity.resolve_identity_id(db, body)
            rescue StandardError => e
              handle_exception(e, level: :warn, handled: true, operation: 'route_attempt_writer.identity')
              nil
            end

            def identity_canonical_name(body)
              raw = body.dig(:identity, :canonical_name) ||
                    body.dig(:identity, :identity) ||
                    body[:caller_identity]
              return nil unless raw && !raw.to_s.empty?

              raw.to_s
            end

            def stable_uuid(value)
              raw = value.to_s
              return raw if raw.length <= 36

              hex = Digest::SHA256.hexdigest(raw)[0, 32]
              "#{hex[0, 8]}-#{hex[8, 4]}-#{hex[12, 4]}-#{hex[16, 4]}-#{hex[20, 12]}"
            end
          end
        end
      end
    end
  end
end
