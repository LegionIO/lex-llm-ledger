# frozen_string_literal: true

require 'digest'
require 'securerandom'
require_relative '../helpers/caller_identity'
require_relative '../helpers/decryption'
require_relative '../helpers/json'
require_relative '../helpers/persistence_logging'

module Legion
  module Extensions
    module Llm
      module Ledger
        module Runners
          module Escalations
            extend self

            def insert(payload:, metadata: {}, **_opts)
              headers = Helpers::SubscriptionMessage.extract_headers(payload, metadata)
              props   = metadata[:properties] || {}

              body = payload.is_a?(Hash) ? payload : Helpers::Decryption.decrypt_if_needed(payload, metadata)

              record = build_escalation_record(body, props, headers)

              Helpers::PersistenceLogging.insert_dataset(
                relation:   Legion::Data::Models::LLM::Conversation.dataset.from(:llm_escalation_events),
                attributes: record,
                operation:  'escalations.insert'
              )
              { result: :ok }
            rescue Sequel::UniqueConstraintViolation => e
              handle_exception(e, level: :debug, handled: true, operation: 'escalations.insert_race')
              { result: :duplicate }
            rescue Helpers::DecryptionUnavailable => e
              handle_exception(e, level: :warn, handled: true, operation: 'escalations.insert.decrypt')
              raise
            rescue Helpers::DecryptionFailed => e
              handle_exception(e, level: :error, handled: true, operation: 'escalations.insert.decrypt')
              raise
            rescue StandardError => e
              handle_exception(e, level: :error, handled: true, operation: 'escalations.insert')
              raise
            end

            alias write_escalation_record insert

            private

            def build_escalation_record(body, props, headers)
              history = Array(body[:history])
              identity = Helpers::CallerIdentity.normalize(
                caller_raw: body[:caller], identity: body[:identity], headers: headers
              )

              first_attempt = history.first || {}
              last_attempt = history.last || {}

              {
                uuid:                    stable_uuid(props[:message_id] || body[:event_id] || SecureRandom.uuid),
                conversation_id:         resolve_conversation_id(body, headers),
                request_ref:             body[:request_id] || props[:correlation_id],
                from_provider:           first_attempt[:provider] || body[:from_provider],
                from_instance:           first_attempt[:instance] || body[:from_instance],
                from_model:              first_attempt[:model] || body[:from_model],
                to_provider:             last_attempt[:provider] || body[:to_provider],
                to_instance:             last_attempt[:instance] || body[:to_instance],
                to_model:                last_attempt[:model] || body[:to_model],
                reason:                  body[:reason] || (first_attempt[:outcome] == 'failure' ? 'provider_failover' : nil),
                error_category:          body[:error_category] || extract_error_category(first_attempt),
                attempt_no:              history.size || (body[:attempt_no] || 1),
                latency_ms:              history.sum { |a| (a[:duration_ms] || 0).to_i } || body[:latency_ms].to_i,
                identity_canonical_name: identity[:identity],
                identity_principal_id:   identity[:principal_id],
                identity_id:             identity[:identity_id],
                history_json:            history.any? ? Helpers::Json.dump(history) : nil,
                outcome:                 body[:outcome]&.to_s,
                total_attempts:          body[:attempts] ? body[:attempts].to_i : history.size,
                recorded_at:             body[:recorded_at] || body[:timestamp] || Time.now.utc,
                inserted_at:             Time.now.utc
              }.compact
            end

            def resolve_conversation_id(body, headers)
              conv_ref = body[:conversation_id] || headers['x-legion-llm-conversation-id']
              return nil unless conv_ref # rubocop:disable Legion/Extension/RunnerReturnHash

              conv = Legion::Data::Models::LLM::Conversation.first(uuid: stable_uuid(conv_ref)) ||
                     Legion::Data::Models::LLM::Conversation.first(uuid: conv_ref)
              conv&.[](:id)
            end

            def extract_error_category(attempt)
              failures = Array(attempt[:failures])
              failures.first.is_a?(Hash) ? failures.first[:category].to_s : nil
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
