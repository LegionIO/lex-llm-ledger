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
          module Skills
            extend self
            extend Legion::Logging::Helper

            def insert(payload: nil, metadata: nil, **message)
              payload, metadata = normalize_insert_args(payload, metadata, message)
              headers = metadata[:headers] || {}
              props   = metadata[:properties] || {}
              body    = payload.is_a?(Hash) ? payload : {}

              record = build_skill_record(body, props, headers)

              Legion::Data::Models::LLM::Conversation.db[:llm_skill_events].insert(record)
              log.info("[ledger] skills.insert uuid=#{record[:uuid]}")
              { result: :ok }
            rescue Sequel::UniqueConstraintViolation => e
              handle_exception(e, level: :warn, handled: true, operation: 'skills.insert_race')
              { result: :duplicate }
            rescue StandardError => e
              handle_exception(e, level: :error, handled: true, operation: 'skills.insert')
              raise
            end

            alias write_skill_record insert

            private

            def build_skill_record(body, props, headers)
              refs  = Legion::Extensions::Llm::Ledger::Helpers::IdentityResolution.resolve_refs(body: body, headers: headers)
              canon = Legion::Extensions::Llm::Ledger::Helpers::IdentityResolution.canonical_name(body: body, headers: headers)
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
                identity_canonical_name: canon,
                identity_principal_id:   refs[:principal_id],
                identity_id:             refs[:identity_id],
                recorded_at:             body[:recorded_at] || body[:timestamp] || Time.now.utc,
                inserted_at:             Time.now.utc
              }
            end

            def resolve_conversation_id(body, headers)
              conv_ref = body[:conversation_id] || headers['x-legion-llm-conversation-id']
              return nil unless conv_ref # rubocop:disable Legion/Extension/RunnerReturnHash

              conv = Legion::Extensions::Llm::Ledger::Runners::Conversations.fetch(ref: conv_ref)
              conv&.[](:id)
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
