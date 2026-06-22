# frozen_string_literal: true

require 'digest'
require 'legion/logging'
require_relative 'stable_identifiers'
require_relative 'json'
require_relative 'persistence_logging'

module Legion
  module Extensions
    module Llm
      module Ledger
        module Helpers
          # Route attempt persistence: persist llm_route_attempts rows.
          # Called after the response row exists during write_prompt/write_metering.
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
          module RouteAttemptPersistence
            extend self
            extend Legion::Logging::Helper
            extend StableIdentifiers

            def write_route_attempts(request, response, body)
              attempts = Array(body[:route_attempt_details])
              return if attempts.empty?

              attempts.each_with_index do |attempt, idx|
                next unless attempt.is_a?(Hash)

                attempt_no = (attempt[:attempt_no] || (idx + 1)).to_i
                uuid = stable_uuid("#{request[:uuid]}:attempt:#{attempt_no}")

                existing = Legion::Data::Models::LLM::RouteAttempt.first(uuid: uuid)
                next if existing

                persist_insert({
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
                                 identity_principal_id:         resolve_identity_principal_id(body),
                                 identity_id:                   resolve_identity_id(body),
                                 identity_canonical_name:       identity_canonical_name(body),
                                 inserted_at:                   Time.now.utc
                               }, operation: 'route_attempt_persistence.insert')
              end
            rescue StandardError => e
              handle_exception(e, level: :warn, handled: true, operation: 'route_attempt_persistence')
            end

            private

            def persist_insert(attrs, operation:)
              Helpers::PersistenceLogging.insert_model(
                model_class:    Legion::Data::Models::LLM::RouteAttempt,
                attributes:     attrs,
                operation:      operation,
                warn_on_unique: false
              )
            end

            def resolve_identity_principal_id(body)
              Helpers::IdentityResolution.caller_identity_refs(body)[:principal_id]
            rescue StandardError => e
              handle_exception(e, level: :warn, handled: true, operation: 'route_attempt.identity_principal')
              nil
            end

            def resolve_identity_id(body)
              Helpers::IdentityResolution.caller_identity_refs(body)[:identity_id]
            rescue StandardError => e
              handle_exception(e, level: :warn, handled: true, operation: 'route_attempt.identity')
              nil
            end

            def identity_canonical_name(body)
              Helpers::IdentityResolution.identity_canonical_name(body)
            end
          end
        end
      end
    end
  end
end
