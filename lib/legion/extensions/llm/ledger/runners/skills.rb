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
          module Skills
            extend self

            def insert(payload:, metadata: {}, **_opts)
              headers = Helpers::SubscriptionMessage.extract_headers(payload, metadata)
              props   = metadata[:properties] || {}

              body = payload.is_a?(Hash) ? payload : Helpers::Decryption.decrypt_if_needed(payload, metadata)

              record = build_skill_record(body, props, headers)

              Helpers::PersistenceLogging.insert_dataset(
                relation:   Legion::Data::Models::LLM::Conversation.dataset.from(:llm_skill_events),
                attributes: record,
                operation:  'skills.insert'
              )
              { result: :ok }
            rescue Sequel::UniqueConstraintViolation => e
              handle_exception(e, level: :debug, handled: true, operation: 'skills.insert_race')
              { result: :duplicate }
            rescue Helpers::DecryptionUnavailable => e
              handle_exception(e, level: :warn, handled: true, operation: 'skills.insert.decrypt')
              raise
            rescue Helpers::DecryptionFailed => e
              handle_exception(e, level: :error, handled: true, operation: 'skills.insert.decrypt')
              raise
            rescue StandardError => e
              handle_exception(e, level: :error, handled: true, operation: 'skills.insert')
              raise
            end

            alias write_skill_record insert

            private

            def build_skill_record(body, props, headers)
              identity = Helpers::CallerIdentity.normalize(
                caller_raw: body[:caller], identity: body[:identity], headers: headers
              )
              skill = body[:skill] || {}

              {
                uuid:                    stable_uuid(props[:message_id] || body[:event_id] || SecureRandom.uuid),
                conversation_id:         resolve_conversation_id(body, headers),
                request_ref:             body[:request_id] || props[:correlation_id],
                skill_name:              skill[:name] || body[:skill_name],
                skill_version:           skill[:version],
                trigger:                 skill[:trigger] || body[:trigger],
                status:                  body[:status] || 'completed',
                duration_ms:             body[:duration_ms].to_i,
                identity_canonical_name: identity[:identity],
                identity_principal_id:   identity[:principal_id],
                identity_id:             identity[:identity_id],
                recorded_at:             body[:recorded_at] || body[:timestamp] || Time.now.utc,
                inserted_at:             Time.now.utc
              }
            end

            def resolve_conversation_id(body, headers)
              conv_ref = body[:conversation_id] || headers['x-legion-llm-conversation-id']
              return nil unless conv_ref # rubocop:disable Legion/Extension/RunnerReturnHash

              conv = Legion::Data::Models::LLM::Conversation.first(uuid: stable_uuid(conv_ref)) ||
                     Legion::Data::Models::LLM::Conversation.first(uuid: conv_ref)
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
