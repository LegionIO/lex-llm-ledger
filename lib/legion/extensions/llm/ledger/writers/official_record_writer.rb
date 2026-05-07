# frozen_string_literal: true

require 'digest'
require 'securerandom'
require_relative '../helpers/json'
require_relative '../helpers/persistence_logging'

module Legion
  module Extensions
    module Llm
      module Ledger
        module Writers
          module OfficialRecordWriter
            module_function

            def write_prompt(payload)
              body = deep_symbolize(payload)
              db = ::Legion::Data.connection
              result = nil

              db.transaction do
                conversation = find_or_create_conversation(db, body)
                user_message = find_or_create_user_message(db, conversation, body)
                request = find_or_create_request(db, conversation, user_message, body)
                response_message = find_or_create_response_message(db, conversation, request, body)
                response = find_or_create_response(db, request, response_message, body)
                link_response_message!(db, response_message, response)
                metric = find_or_create_metric(db, request, response, body)
                result = { result: :ok, request_id: request[:id], response_id: response[:id], metric_id: metric[:id] }
              end

              result
            end

            def write_metering(payload)
              body = deep_symbolize(payload)
              db = ::Legion::Data.connection
              result = nil

              db.transaction do
                conversation = find_or_create_conversation(db, body)
                user_message = find_or_create_user_message(db, conversation, body)
                request = find_or_create_request(db, conversation, user_message, body)
                response = find_or_create_response(db, request, nil, body)
                metric = find_or_create_metric(db, request, response, body)
                result = { result: :ok, request_id: request[:id], response_id: response[:id], metric_id: metric[:id] }
              end

              result
            end

            def find_or_create_conversation(db, body)
              uuid = stable_uuid(reference(body, :conversation_id, :conversation_ref) || 'default-conversation')
              existing = db[:llm_conversations].where(uuid: uuid).first
              return existing if existing

              id = insert_row(db, :llm_conversations, {
                                uuid:                 uuid,
                                title:                body[:title] || body[:conversation_title],
                                classification_level: classification_level(body),
                                contains_phi:         contains_phi?(body),
                                contains_pii:         contains_pii?(body),
                                retention_policy:     body[:retention_policy] || 'default',
                                expires_at:           body[:expires_at],
                                recorded_at:          recorded_at(body),
                                inserted_at:          Time.now.utc,
                                created_at:           Time.now.utc,
                                updated_at:           Time.now.utc
                              }, operation: 'official_record_writer.conversation')
              db[:llm_conversations][id: id]
            end

            def find_or_create_user_message(db, conversation, body)
              uuid = stable_uuid(reference(body, :message_id, :message_id_ctx) || "request-message:#{request_ref(body)}")
              existing = db[:llm_messages].where(uuid: uuid).first
              return existing if existing

              seq = body[:message_seq] ? integer(body[:message_seq]) : next_message_seq(db, conversation)
              id = insert_row(db, :llm_messages, {
                                uuid:            uuid,
                                conversation_id: conversation[:id],
                                seq:             seq,
                                role:            'user',
                                content_type:    'text',
                                content:         request_content(body),
                                input_tokens:    tokens(body)[:input_tokens],
                                output_tokens:   0,
                                created_at:      recorded_at(body),
                                inserted_at:     Time.now.utc
                              }, operation: 'official_record_writer.user_message')
              db[:llm_messages][id: id]
            end

            def find_or_create_request(db, conversation, latest_message, body)
              request_id = request_ref(body)
              existing = db[:llm_message_inference_requests].where(request_ref: request_id).first
              return existing if existing

              operation = operation(body)
              id = insert_row(db, :llm_message_inference_requests, {
                                uuid:                  stable_uuid(request_id),
                                conversation_id:       conversation[:id],
                                latest_message_id:     latest_message[:id],
                                caller_principal_id:   body[:caller_principal_id],
                                caller_identity_id:    body[:caller_identity_id],
                                runtime_caller_type:   body[:caller_type],
                                request_ref:           request_id,
                                correlation_ref:       correlation_id(body),
                                correlation_id:        correlation_id(body),
                                exchange_ref:          body[:exchange_id],
                                request_type:          operation,
                                operation:             operation,
                                idempotency_key:       body[:idempotency_key] || request_id,
                                status:                'responded',
                                context_message_count: Array(body.dig(:request, :messages) || body[:messages]).size,
                                request_capture_mode:  'full',
                                request_json:          json_dump(request_payload(body)),
                                classification_level:  classification_level(body),
                                cost_center:           billing(body)[:cost_center],
                                budget_key:            billing(body)[:budget_id] || billing(body)[:budget_key],
                                requested_at:          recorded_at(body),
                                inserted_at:           Time.now.utc
                              }, operation: 'official_record_writer.inference_request')
              db[:llm_message_inference_requests][id: id]
            end

            def find_or_create_response_message(db, conversation, request, body)
              uuid = stable_uuid(reference(body, :response_message_id) || "response-message:#{request_ref(body)}")
              existing = db[:llm_messages].where(uuid: uuid).first
              return existing if existing

              latest = db[:llm_messages][id: request[:latest_message_id]]
              id = insert_row(db, :llm_messages, {
                                uuid:                         uuid,
                                conversation_id:              conversation[:id],
                                parent_message_id:            latest&.dig(:id),
                                message_inference_request_id: request[:id],
                                seq:                          (latest&.dig(:seq) || 1) + 1,
                                role:                         'assistant',
                                content_type:                 'text',
                                content:                      response_content(body),
                                input_tokens:                 0,
                                output_tokens:                tokens(body)[:output_tokens],
                                created_at:                   recorded_at(body),
                                inserted_at:                  Time.now.utc
                              }, operation: 'official_record_writer.response_message')
              db[:llm_messages][id: id]
            end

            def find_or_create_response(db, request, response_message, body)
              response_uuid = stable_uuid(reference(body, :provider_response_ref) || "response:#{request_ref(body)}")
              existing = db[:llm_message_inference_responses].where(uuid: response_uuid).first
              return existing if existing

              id = insert_row(db, :llm_message_inference_responses, {
                                uuid:                         response_uuid,
                                message_inference_request_id: request[:id],
                                response_message_id:          response_message&.dig(:id),
                                provider:                     provider(body),
                                provider_instance:            provider_instance(body),
                                model_key:                    model_id(body),
                                tier:                         tier(body),
                                runner_ref:                   body[:worker_id] || body[:runner_ref],
                                provider_response_ref:        body[:provider_response_ref],
                                status:                       body[:error] ? 'error' : 'success',
                                finish_reason:                finish_reason(body),
                                latency_ms:                   integer(body[:latency_ms]),
                                wall_clock_ms:                integer(body[:wall_clock_ms]),
                                response_capture_mode:        'full',
                                response_json:                json_dump(visible_response(body)),
                                response_thinking_json:       json_dump(thinking_response(body)),
                                dispatch_path:                body[:dispatch_path] || body[:tier],
                                responded_at:                 recorded_at(body),
                                inserted_at:                  Time.now.utc
                              }, operation: 'official_record_writer.inference_response')
              db[:llm_message_inference_responses][id: id]
            end

            def find_or_create_metric(db, request, response, body)
              metric_uuid = stable_uuid(reference(body, :message_id) || "metric:#{request_ref(body)}")
              existing = db[:llm_message_inference_metrics].where(uuid: metric_uuid).first
              return existing if existing

              token_values = tokens(body)
              id = insert_row(db, :llm_message_inference_metrics, {
                                uuid:                          metric_uuid,
                                message_inference_request_id:  request[:id],
                                message_inference_response_id: response[:id],
                                provider:                      provider(body),
                                model_key:                     model_id(body),
                                tier:                          tier(body),
                                input_tokens:                  token_values[:input_tokens],
                                output_tokens:                 token_values[:output_tokens],
                                thinking_tokens:               token_values[:thinking_tokens],
                                total_tokens:                  token_values[:total_tokens],
                                latency_ms:                    integer(body[:latency_ms]),
                                wall_clock_ms:                 integer(body[:wall_clock_ms]),
                                cost_usd:                      cost_usd(body),
                                currency:                      body[:currency] || 'USD',
                                cost_center:                   billing(body)[:cost_center],
                                budget_key:                    billing(body)[:budget_id] || billing(body)[:budget_key],
                                recorded_at:                   recorded_at(body),
                                inserted_at:                   Time.now.utc
                              }, operation: 'official_record_writer.inference_metric')
              db[:llm_message_inference_metrics][id: id]
            end

            def insert_row(db, table, attributes, operation:)
              Helpers::PersistenceLogging.insert_row(db, table, attributes, operation: operation)
            end

            def request_ref(body)
              body[:__ledger_request_ref] ||= reference(body, :request_id, :request_ref) ||
                                              correlation_id(body) ||
                                              stable_uuid(SecureRandom.uuid)
            end

            def link_response_message!(db, response_message, response)
              return unless response_message && response
              return if response_message[:message_inference_response_id] == response[:id]

              db[:llm_messages].where(id: response_message[:id]).update(message_inference_response_id: response[:id])
            end

            def correlation_id(body)
              reference(body, :correlation_id, :correlation_ref) || body.dig(:tracing, :correlation_id)
            end

            def operation(body)
              (body[:operation] || body[:request_type] || body.dig(:routing, :operation) ||
                body.dig(:headers, :'x-legion-llm-request-type') || 'chat').to_s
            end

            def provider(body)
              (body[:provider] || body.dig(:routing, :provider)).to_s
            end

            def provider_instance(body)
              body[:provider_instance] || body.dig(:routing, :provider_instance) || body.dig(:routing, :instance)
            end

            def model_id(body)
              body[:model_id] || body[:model_key] || body.dig(:routing, :model)
            end

            def tier(body)
              body[:tier] || body.dig(:routing, :tier)
            end

            def tokens(body)
              raw = body[:tokens] || body
              input = integer(raw[:input_tokens] || raw[:input])
              output = integer(raw[:output_tokens] || raw[:output])
              thinking = integer(raw[:thinking_tokens] || raw[:thinking])
              total = integer(raw[:total_tokens] || raw[:total], default: input + output + thinking)

              { input_tokens: input, output_tokens: output, thinking_tokens: thinking, total_tokens: total }
            end

            def billing(body)
              body[:billing] || body[:cost] || {}
            end

            def cost_usd(body)
              raw = body[:cost_usd] || body.dig(:cost, :estimated_usd) || body.dig(:cost, :usd)
              raw.to_f
            end

            def request_payload(body)
              body[:request] || body[:messages] || {}
            end

            def request_content(body)
              messages = body.dig(:request, :messages) || body[:messages]
              message = Array(messages).reverse.find { |item| item[:role].to_s == 'user' } || Array(messages).last
              content = message&.dig(:content) || body[:prompt] || body[:text]
              stringify_content(content)
            end

            def visible_response(body)
              response = body[:response] || body[:response_content] || body[:content] || {}
              return { content: response } if response.is_a?(String)
              return { content: response[:content] } if response.is_a?(Hash) && response.key?(:content)

              response.is_a?(Hash) ? response.except(:thinking) : { content: response.to_s }
            end

            def thinking_response(body)
              thinking = body[:response_thinking] || body[:thinking] || body.dig(:response, :thinking)
              return {} if thinking.nil?
              return { content: thinking } if thinking.is_a?(String)

              thinking
            end

            def response_content(body)
              stringify_content(visible_response(body)[:content] || visible_response(body).dig(:message, :content))
            end

            def finish_reason(body)
              body[:finish_reason] || body.dig(:response, :finish_reason) || body.dig(:response, :stop, :reason)
            end

            def classification_level(body)
              body[:classification_level] || body.dig(:classification, :level)
            end

            def contains_phi?(body)
              body[:contains_phi] || body.dig(:classification, :contains_phi) || false
            end

            def contains_pii?(body)
              body[:contains_pii] || body.dig(:classification, :contains_pii) || false
            end

            def recorded_at(body)
              body[:recorded_at] || body[:timestamp] || body.dig(:timestamps, :returned) || body.dig(:timestamps, :provider_end) || Time.now.utc
            end

            def reference(body, *keys)
              keys.lazy.map { |key| body[key] }.find { |value| present?(value) }&.to_s
            end

            def stable_uuid(value)
              raw = value.to_s
              return raw if raw.length <= 36

              hex = Digest::SHA256.hexdigest(raw)[0, 32]
              "#{hex[0, 8]}-#{hex[8, 4]}-#{hex[12, 4]}-#{hex[16, 4]}-#{hex[20, 12]}"
            end

            def next_message_seq(db, conversation)
              db[:llm_messages].where(conversation_id: conversation[:id]).max(:seq).to_i + 1
            end

            def integer(value, default: 0)
              return default if value.nil?

              value.to_i
            end

            def stringify_content(content)
              return nil if content.nil?
              return content if content.is_a?(String)

              json_dump(content)
            end

            def json_dump(value)
              Helpers::Json.dump(value)
            end

            def deep_symbolize(value)
              case value
              when Hash
                value.each_with_object({}) { |(key, item), memo| memo[key.to_sym] = deep_symbolize(item) }
              when Array
                value.map { |item| deep_symbolize(item) }
              else
                value
              end
            end

            def present?(value)
              !value.nil? && !(value.respond_to?(:empty?) && value.empty?)
            end
          end
        end
      end
    end
  end
end
