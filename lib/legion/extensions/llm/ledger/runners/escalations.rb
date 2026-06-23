# frozen_string_literal: true

require 'digest'
require 'securerandom'
require 'legion/json'
require 'legion/logging'
require 'legion/data/model'
require_relative '../helpers/identity_resolution'
require_relative 'conversations'

module Legion
  module Extensions
    module Llm
      module Ledger
        module Runners
          module Escalations
            extend self
            extend Legion::Logging::Helper

            def insert(payload: nil, metadata: nil, **message)
              payload, metadata = normalize_insert_args(payload, metadata, message)
              headers = metadata[:headers] || {}
              props   = metadata[:properties] || {}
              body    = payload.is_a?(Hash) ? payload : {}

              record = build_escalation_record(body, props, headers)

              Legion::Data::Models::LLM::Conversation.db[:llm_escalation_events].insert(record)
              log.info("[ledger] escalations.insert uuid=#{record[:uuid]}")
              { result: :ok }
            rescue Sequel::UniqueConstraintViolation => e
              handle_exception(e, level: :warn, handled: true, operation: 'escalations.insert_race')
              { result: :duplicate }
            rescue StandardError => e
              handle_exception(e, level: :error, handled: true, operation: 'escalations.insert')
              raise
            end

            alias write_escalation_record insert

            private

            def build_escalation_record(body, props, headers)
              history  = Array(body[:history])
              refs     = Legion::Extensions::Llm::Ledger::Helpers::IdentityResolution.resolve_refs(body: body, headers: headers)
              canon    = Legion::Extensions::Llm::Ledger::Helpers::IdentityResolution.canonical_name(body: body, headers: headers)

              first_attempt = history.first || {}
              last_attempt  = history.last || {}

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
                identity_canonical_name: canon,
                identity_principal_id:   refs[:principal_id],
                identity_id:             refs[:identity_id],
                history_json:            history.any? ? Legion::JSON.dump(history) : nil, # rubocop:disable Legion/HelperMigration/DirectJson
                outcome:                 body[:outcome]&.to_s,
                total_attempts:          body[:attempts] ? body[:attempts].to_i : history.size,
                recorded_at:             body[:recorded_at] || body[:timestamp] || Time.now.utc,
                inserted_at:             Time.now.utc
              }.compact
            end

            def resolve_conversation_id(body, headers)
              conv_ref = body[:conversation_id] || headers['x-legion-llm-conversation-id']
              return nil unless conv_ref # rubocop:disable Legion/Extension/RunnerReturnHash

              conv = Legion::Extensions::Llm::Ledger::Runners::Conversations.fetch(ref: conv_ref)
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
