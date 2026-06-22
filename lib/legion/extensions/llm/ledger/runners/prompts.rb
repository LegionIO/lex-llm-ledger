# frozen_string_literal: true

require 'legion/extensions/llm/responses/thinking_extractor'
require_relative '../helpers/subscription_message'
require_relative '../helpers/caller_identity'
require_relative '../helpers/json'
require_relative '../helpers/retention'

module Legion
  module Extensions
    module Llm
      module Ledger
        module Runners
          module Prompts
            ALLOWED_CLASSIFICATION_LEVELS = %w[public internal confidential restricted].freeze

            extend self

            # Persist a prompt/payload record into the official lifecycle schema.
            def insert(payload:, metadata: {}, **_opts)
              headers = Helpers::SubscriptionMessage.extract_headers(payload, metadata)
              props   = metadata[:properties] || {}

              body = payload.is_a?(Hash) ? payload : Helpers::Decryption.decrypt_if_needed(payload, metadata)
              ctx  = body[:message_context] || {}

              expires_at = Helpers::Retention.resolve(
                retention:    headers['x-legion-retention'],
                contains_phi: headers['x-legion-contains-phi'] == 'true'
              )

              body.merge!(official_context_payload(body, ctx, props, headers))
              body.merge!(official_identity_payload(body, headers))
              body.merge!(official_routing_payload(body, headers))
              body.merge!(official_compliance_payload(body, headers, expires_at))

              Helpers::LifecyclePersistence.write_prompt(::Legion::Data.connection, body)
            rescue Helpers::DecryptionUnavailable => e
              handle_exception(e, level: :warn, handled: true, operation: 'prompts.insert.decrypt')
              raise
            rescue Helpers::DecryptionFailed => e
              handle_exception(e, level: :error, handled: true, operation: 'prompts.insert.decrypt')
              raise
            end

            # Link a response message row to an inference response row.
            def link(response_message_id:, response_id:, **_opts)
              return { result: :ok } unless response_message_id && response_id

              db = ::Legion::Data.connection
              Helpers::ResponseMessageLinking.response_message_linking_link_response_message!(
                db,
                db[:llm_messages][response_message_id],
                db[:llm_message_inference_responses][response_id]
              )
              { result: :ok }
            rescue StandardError => e
              handle_exception(e, level: :warn, handled: true, operation: 'prompts.link')
              { result: :ok }
            end

            private

            def official_prompt_payload(body, ctx, props, headers, expires_at)
              body.merge(
                official_context_payload(body, ctx, props, headers),
                official_identity_payload(body, headers),
                official_routing_payload(body, headers),
                official_compliance_payload(body, headers, expires_at)
              )
            end

            def official_identity_payload(body, headers)
              identity = Helpers::CallerIdentity.normalize(
                caller_raw: body[:caller], identity: body[:identity], headers: headers
              )
              {
                caller_identity:       identity[:identity],
                caller_type:           identity[:type],
                __header_principal_id: identity[:principal_id],
                __header_identity_id:  identity[:identity_id]
              }.compact
            end

            def official_context_payload(body, ctx, props, headers)
              {
                message_id:          props[:message_id] || body[:message_id] || ctx[:message_id],
                correlation_id:      props[:correlation_id] || body[:correlation_id],
                conversation_id:     ctx[:conversation_id] || body[:conversation_id] || headers['x-legion-llm-conversation-id'],
                response_message_id: body[:response_message_id],
                request_id:          ctx[:request_id] || body[:request_id] || headers['x-legion-llm-request-id'],
                exchange_id:         ctx[:exchange_id] || body[:exchange_id]
              }
            end

            def official_routing_payload(body, headers)
              routing = body[:routing] || {}
              {
                operation:         body[:operation] || body[:request_type] || headers['x-legion-llm-request-type'],
                provider:          routing[:provider] || body[:provider] || headers['x-legion-llm-provider'],
                provider_instance: routing[:provider_instance] || routing[:instance] || body[:provider_instance],
                model_id:          routing[:model] || body[:model_id] || headers['x-legion-llm-model'],
                tier:              routing[:tier] || body[:tier] || headers['x-legion-llm-tier']
              }
            end

            def official_compliance_payload(body, headers, expires_at)
              cls = body[:classification] || {}
              {
                retention_policy: headers['x-legion-retention'] || body[:retention_policy],
                expires_at:       expires_at,
                contains_phi:     headers['x-legion-contains-phi'] == 'true' || cls[:contains_phi],
                contains_pii:     cls[:contains_pii] ? true : false
              }.tap do |p|
                p[:classification_level] = Helpers::LifecycleEnrichment.classification_level(
                  classification: { level: cls[:level] || headers['x-legion-classification'] }
                )
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
