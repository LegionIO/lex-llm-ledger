# frozen_string_literal: true

require_relative '../helpers/subscription_message'
require_relative '../helpers/caller_identity'
require_relative '../helpers/lifecycle_persistence'
require_relative '../helpers/retention'

module Legion
  module Extensions
    module Llm
      module Ledger
        module Runners
          module Metering
            extend self

            # Persist a metering record into the official lifecycle schema.
            def insert(payload:, metadata: {}, **_opts)
              headers = Helpers::SubscriptionMessage.extract_headers(payload, metadata)
              ctx     = payload[:message_context] || {}
              props   = metadata[:properties] || {}

              body = official_metering_payload(payload, ctx, props, headers)
              body.merge!(official_identity_payload(body, headers))
              Helpers::LifecyclePersistence.write_metering(body)
            end

            # Look up a metric by request reference.
            def find(request_ref:, **_opts)
              return { result: :not_found } unless request_ref

              request = Legion::Data::Models::LLM::MessageInferenceRequest.lookup(request_ref)
              return { result: :not_found } unless request

              metric = Legion::Data::Models::LLM::MessageInferenceMetric
                       .first(message_inference_request_id: request[:id])
              return { result: :not_found } unless metric

              { result: :ok, metric: metric.to_h }
            rescue StandardError => e
              handle_exception(e, level: :warn, handled: true, operation: 'metering.find')
              { result: :error, error: e.message }
            end

            private

            def official_metering_payload(payload, ctx, props, headers)
              identity = Helpers::CallerIdentity.normalize(
                caller_raw: payload[:caller], identity: payload[:identity], headers: headers
              )
              payload.merge(
                message_id:            props[:message_id] || payload[:message_id] || ctx[:message_id],
                correlation_id:        props[:correlation_id] || payload[:correlation_id],
                conversation_id:       ctx[:conversation_id] || payload[:conversation_id],
                request_id:            ctx[:request_id] || payload[:request_id],
                exchange_id:           ctx[:exchange_id] || payload[:exchange_id],
                operation:             payload[:operation] || payload[:request_type] || headers['x-legion-llm-request-type'],
                provider:              payload[:provider] || headers['x-legion-llm-provider'],
                provider_instance:     payload[:provider_instance] || payload[:instance],
                model_id:              payload[:model_id] || headers['x-legion-llm-model'],
                tier:                  payload[:tier] || headers['x-legion-llm-tier'],
                caller_identity:       identity[:identity],
                caller_type:           identity[:type],
                __header_principal_id: identity[:principal_id],
                __header_identity_id:  identity[:identity_id]
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

            include Legion::Extensions::Helpers::Lex if Legion::Extensions.const_defined?(:Helpers, false) &&
                                                        Legion::Extensions::Helpers.const_defined?(:Lex, false)
          end
        end
      end
    end
  end
end
