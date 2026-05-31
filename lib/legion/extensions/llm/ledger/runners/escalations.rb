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
          module Escalations
            extend self

            def write_escalation_record(payload = nil, metadata = {}, **message)
              payload, metadata = normalize_runner_args(payload, metadata, message)
              headers = Helpers::SubscriptionMessage.extract_headers(payload, metadata)
              props   = metadata[:properties] || {}

              body = payload.is_a?(Hash) ? payload : Helpers::Decryption.decrypt_if_needed(payload, metadata)

              db = ::Legion::Data.connection
              record = build_escalation_record(db, body, props, headers)

              Helpers::PersistenceLogging.insert_row(
                db, :llm_escalation_events, record,
                operation: 'write_escalation_record'
              )
              { result: :ok }
            rescue Sequel::UniqueConstraintViolation => e
              log.warn("write_escalation_record duplicate insert ignored: #{e.message}")
              { result: :duplicate }
            rescue Helpers::DecryptionUnavailable => e
              handle_exception(e, level: :warn, handled: true, operation: 'write_escalation_record.decrypt')
              raise
            rescue Helpers::DecryptionFailed => e
              handle_exception(e, level: :error, handled: true, operation: 'write_escalation_record.decrypt')
              raise
            rescue StandardError => e
              handle_exception(e, level: :error, handled: true, operation: 'write_escalation_record')
              { result: :error, error: e.message }
            end

            private

            def normalize_runner_args(payload, metadata, message)
              Helpers::SubscriptionMessage.runner_args(payload, metadata, message)
            end

            def build_escalation_record(db, body, props, headers)
              identity = Helpers::CallerIdentity.normalize(
                caller_raw: body[:caller], identity: body[:identity], headers: headers
              )

              {
                uuid:                    stable_uuid(props[:message_id] || body[:event_id] || SecureRandom.uuid),
                conversation_id:         resolve_conversation_id(db, body, headers),
                request_ref:             body[:request_id] || props[:correlation_id],
                from_provider:           body[:from_provider] || body.dig(:escalation, :from_provider),
                from_instance:           body[:from_instance] || body.dig(:escalation, :from_instance),
                from_model:              body[:from_model] || body.dig(:escalation, :from_model),
                to_provider:             body[:to_provider] || body.dig(:escalation, :to_provider),
                to_instance:             body[:to_instance] || body.dig(:escalation, :to_instance),
                to_model:                body[:to_model] || body.dig(:escalation, :to_model),
                reason:                  body[:reason] || body.dig(:escalation, :reason),
                error_category:          body[:error_category] || body.dig(:escalation, :error_category),
                attempt_no:              (body[:attempt_no] || body.dig(:escalation, :attempt_no)).to_i,
                latency_ms:              body[:latency_ms].to_i,
                identity_canonical_name: identity[:identity],
                identity_principal_id:   identity[:principal_id],
                identity_id:             identity[:identity_id],
                schema_version:          Writers::OfficialRecordWriter::SCHEMA_VERSION,
                recorded_at:             body[:recorded_at] || body[:timestamp] || Time.now.utc,
                inserted_at:             Time.now.utc
              }
            end

            def resolve_conversation_id(db, body, headers)
              conv_ref = body[:conversation_id] || headers['x-legion-llm-conversation-id']
              return nil unless conv_ref # rubocop:disable Legion/Extension/RunnerReturnHash

              conv = db[:llm_conversations].where(uuid: stable_uuid(conv_ref)).first ||
                     db[:llm_conversations].where(uuid: conv_ref).first
              conv&.[](:id)
            end

            def stable_uuid(value)
              raw = value.to_s
              return raw if raw.length <= 36 # rubocop:disable Legion/Extension/RunnerReturnHash

              hex = Digest::SHA256.hexdigest(raw)[0, 32]
              "#{hex[0, 8]}-#{hex[8, 4]}-#{hex[12, 4]}-#{hex[16, 4]}-#{hex[20, 12]}"
            end

            include Legion::Extensions::Helpers::Lex if Legion::Extensions.const_defined?(:Helpers, false) &&
                                                        Legion::Extensions::Helpers.const_defined?(:Lex, false)
          end
        end
      end
    end
  end
end
