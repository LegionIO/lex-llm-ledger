# frozen_string_literal: true

require 'legion/extensions/llm/responses/thinking_extractor'
require_relative 'stable_identifiers'
require_relative 'request_refs'
require_relative 'identity_resolution'
require_relative 'lifecycle_enrichment'
require_relative 'response_message_linking'
require_relative 'route_attempt_persistence'

module Legion
  module Extensions
    module Llm
      module Ledger
        module Helpers
          module LifecyclePersistence
            extend Legion::Logging::Helper
            extend StableIdentifiers
            extend RequestRefs

            module_function

            def write_prompt(body)
              conversation = find_or_create_conversation(body)
              user_message = find_or_create_user_message(conversation, body)
              request = find_or_create_request(conversation, user_message, body)
              response_message = find_or_create_response_message(conversation, request, body)
              response = find_or_create_response(request, response_message, body)
              ResponseMessageLinking.response_message_linking_link_response_message!(response_message, response)
              metric = find_or_create_metric(request, response, body)
              RouteAttemptPersistence.write_route_attempts(request, response, body)
              { result: :ok, request_id: request[:id], response_id: response[:id], metric_id: metric[:id] }
            end

            def write_metering(body)
              conversation = find_or_create_conversation(body)
              request = find_or_create_request(conversation, nil, body)
              response = find_or_create_response(request, nil, body)
              metric = find_or_create_metric(request, response, body)
              RouteAttemptPersistence.write_route_attempts(request, response, body)
              { result: :ok, request_id: request[:id], response_id: response[:id], metric_id: metric[:id] }
            end

            def find_or_create_conversation(body)
              uuid = stable_uuid(reference(body, :conversation_id, :conversation_ref) || 'default-conversation')
              existing = llm_conversation_model.first(uuid: uuid)
              return existing if existing

              conversation_id = persist_model(
                model_class: llm_conversation_model,
                attrs:       {
                  uuid:                    uuid,
                  title:                   body[:title] || body[:conversation_title],
                  classification_level:    classification_level(body),
                  contains_phi:            LifecycleEnrichment.contains_phi?(body),
                  contains_pii:            LifecycleEnrichment.contains_pii?(body),
                  pii_types_json:          LifecycleEnrichment.json_dump(Array(body.dig(:classification, :pii_types))),
                  jurisdictions_json:      LifecycleEnrichment.json_dump(Array(body.dig(:classification, :jurisdictions) || body[:jurisdictions])),
                  retention_policy:        body[:retention_policy] || 'default',
                  expires_at:              body[:expires_at],
                  identity_canonical_name: IdentityResolution.identity_canonical_name(body),
                  recorded_at:             LifecycleEnrichment.recorded_at(body),
                  inserted_at:             Time.now.utc,
                  created_at:              Time.now.utc,
                  updated_at:              Time.now.utc
                },
                operation:   'lifecycle_persistence.conversation'
              )
              llm_conversation_model[conversation_id]
            rescue Sequel::UniqueConstraintViolation => e
              handle_exception(e, level: :debug, handled: true, operation: 'lifecycle_persistence.conversation_race')
              llm_conversation_model.first(uuid: uuid)
            end

            def find_or_create_user_message(conversation, body)
              uuid = stable_uuid(reference(body, :message_id, :message_id_ctx) || "request-message:#{request_ref(body)}")
              existing = llm_message_model.first(uuid: uuid)
              return existing if existing

              seq = body[:message_seq] ? LifecycleEnrichment.integer(body[:message_seq]) : next_message_seq(conversation)
              identity_refs = IdentityResolution.caller_identity_refs(body)
              message_id = persist_model(
                model_class: llm_message_model,
                attrs:       {
                  uuid:                    uuid,
                  conversation_id:         conversation[:id],
                  seq:                     seq,
                  role:                    'user',
                  content_type:            'text',
                  content:                 LifecycleEnrichment.request_content(body),
                  input_tokens:            tokens(body)[:input_tokens],
                  output_tokens:           0,
                  identity_principal_id:   identity_refs[:principal_id],
                  identity_id:             identity_refs[:identity_id],
                  identity_canonical_name: IdentityResolution.identity_canonical_name(body),
                  created_at:              LifecycleEnrichment.recorded_at(body),
                  inserted_at:             Time.now.utc
                },
                operation:   'lifecycle_persistence.user_message'
              )
              llm_message_model[message_id]
            rescue Sequel::UniqueConstraintViolation => e
              handle_exception(e, level: :debug, handled: true, operation: 'lifecycle_persistence.user_message_race')
              llm_message_model.first(uuid: uuid) ||
                llm_message_model.first(conversation_id: conversation[:id], seq: seq)
            end

            def find_or_create_request(conversation, latest_message, body)
              request_id = request_ref(body)
              existing = llm_request_model.lookup(request_id)
              return LifecycleEnrichment.enrich_request!(existing, body, latest_message) if existing

              operation = LifecycleEnrichment.operation(body)
              identity_refs = IdentityResolution.caller_identity_refs(body)
              request_row_id = persist_model(
                model_class: llm_request_model,
                attrs:       {
                  uuid:                    stable_uuid(request_id),
                  conversation_id:         conversation[:id],
                  latest_message_id:       latest_message&.[](:id),
                  parent_request_id:       LifecycleEnrichment.resolve_parent_request_id(body),
                  caller_principal_id:     identity_refs[:principal_id],
                  caller_identity_id:      identity_refs[:identity_id],
                  identity_canonical_name: IdentityResolution.identity_canonical_name(body),
                  runtime_caller_type:     LifecycleEnrichment.caller_type(body),
                  runtime_caller_class:    LifecycleEnrichment.runtime_caller_class(body),
                  runtime_caller_client:   LifecycleEnrichment.runtime_caller_client(body),
                  request_ref:             request_id,
                  correlation_ref:         LifecycleEnrichment.correlation_id(body),
                  correlation_id:          LifecycleEnrichment.correlation_id(body),
                  exchange_ref:            body[:exchange_id],
                  request_type:            operation,
                  operation:               operation,
                  idempotency_key:         body[:idempotency_key] || request_id,
                  status:                  'responded',
                  context_message_count:   Array(body.dig(:request, :messages) || body[:messages]).size,
                  request_capture_mode:    'full',
                  request_json:            request_payload_json(body),
                  classification_level:    classification_level(body),
                  cost_center:             LifecycleEnrichment.billing(body)[:cost_center],
                  budget_key:              LifecycleEnrichment.billing(body)[:budget_id] || LifecycleEnrichment.billing(body)[:budget_key],
                  injected_tool_count:     Array(body.dig(:audit, :injected_tools) || body[:injected_tools]).size,
                  context_tokens:          LifecycleEnrichment.resolve_context_tokens(body),
                  request_content_hash:    LifecycleEnrichment.resolve_request_content_hash(body),
                  curation_strategy:       body[:curation_strategy] || body.dig(:audit, :curation_strategy),
                  tool_policy:             body[:tool_policy] || body.dig(:audit, :tool_policy),
                  requested_at:            LifecycleEnrichment.recorded_at(body),
                  inserted_at:             Time.now.utc
                },
                operation:   'lifecycle_persistence.inference_request'
              )
              llm_request_model[request_row_id]
            rescue Sequel::UniqueConstraintViolation => e
              handle_exception(e, level: :debug, handled: true, operation: 'lifecycle_persistence.request_race')
              existing = llm_request_model.lookup(request_id)
              return LifecycleEnrichment.enrich_request!(existing, body, latest_message) if existing

              raise
            end

            def find_or_create_response_message(conversation, request, body)
              uuid = stable_uuid(reference(body, :response_message_id) || "response-message:#{request_ref(body)}")
              existing = llm_message_model.first(uuid: uuid)
              return existing if existing

              latest = llm_message_model[request[:latest_message_id]]
              seq = (latest&.[](:seq) || 1) + 1
              identity_refs = IdentityResolution.caller_identity_refs(body)
              message_id = persist_model(
                model_class: llm_message_model,
                attrs:       {
                  uuid:                         uuid,
                  conversation_id:              conversation[:id],
                  parent_message_id:            latest&.[](:id),
                  message_inference_request_id: request[:id],
                  seq:                          seq,
                  role:                         'assistant',
                  content_type:                 'text',
                  content:                      LifecycleEnrichment.response_content(body),
                  input_tokens:                 0,
                  output_tokens:                LifecycleEnrichment.token_count(body, :output_tokens),
                  identity_principal_id:        identity_refs[:principal_id],
                  identity_id:                  identity_refs[:identity_id],
                  identity_canonical_name:      IdentityResolution.identity_canonical_name(body),
                  created_at:                   LifecycleEnrichment.recorded_at(body),
                  inserted_at:                  Time.now.utc
                },
                operation:   'lifecycle_persistence.response_message'
              )
              llm_message_model[message_id]
            rescue Sequel::UniqueConstraintViolation => e
              handle_exception(e, level: :debug, handled: true, operation: 'lifecycle_persistence.response_message_race')
              llm_message_model.first(uuid: uuid) ||
                llm_message_model.first(conversation_id: conversation[:id], seq: seq)
            end

            def find_or_create_response(request, response_message, body)
              response_ref = reference(body, :provider_response_ref) ||
                             "response:#{request_ref(body)}:#{LifecycleEnrichment.provider(body) || 'unknown'}"
              response_uuid = stable_uuid(response_ref)
              existing = llm_response_model.first(uuid: response_uuid)
              existing ||= request.message_inference_responses_dataset.first

              if existing
                LifecycleEnrichment.enrich_response!(existing, response_message, body)
                return existing
              end

              visible = LifecycleEnrichment.visible_response(body)
              thinking = LifecycleEnrichment.thinking_response(body)
              is_phi = LifecycleEnrichment.contains_phi?(body)
              identity_refs = IdentityResolution.caller_identity_refs(body)

              response_row_id = persist_model(
                model_class: llm_response_model,
                attrs:       {
                  uuid:                         response_uuid,
                  message_inference_request_id: request[:id],
                  response_message_id:          response_message&.[](:id),
                  provider:                     LifecycleEnrichment.provider(body),
                  provider_instance:            LifecycleEnrichment.provider_instance(body),
                  model_key:                    LifecycleEnrichment.model_id(body),
                  tier:                         LifecycleEnrichment.tier(body),
                  runner_ref:                   body[:worker_id] || body[:runner_ref],
                  provider_response_ref:        body[:provider_response_ref],
                  status:                       body[:error] ? 'error' : 'success',
                  finish_reason:                LifecycleEnrichment.finish_reason(body),
                  latency_ms:                   LifecycleEnrichment.integer(body[:latency_ms]),
                  wall_clock_ms:                LifecycleEnrichment.integer(body[:wall_clock_ms]),
                  response_capture_mode:        'full',
                  response_json:                visible ? LifecycleEnrichment.phi_protect(LifecycleEnrichment.storage_json_dump(visible), is_phi) : nil,
                  response_thinking_json:       thinking ? LifecycleEnrichment.phi_protect(LifecycleEnrichment.storage_json_dump(thinking), is_phi) : nil,
                  dispatch_path:                body[:dispatch_path] || body[:tier],
                  error_category:               body[:error_category] || body.dig(:error, :category),
                  error_code:                   body[:error_code] || body.dig(:error, :code),
                  error_message:                body[:error_message] || body.dig(:error, :message),
                  response_content_hash:        LifecycleEnrichment.resolve_response_content_hash(body),
                  route_attempts:               (body[:route_attempts] || body.dig(:audit, :route_attempts)).to_i,
                  escalation_chain_ref:         body[:escalation_chain_ref],
                  identity_principal_id:        identity_refs[:principal_id],
                  identity_id:                  identity_refs[:identity_id],
                  identity_canonical_name:      IdentityResolution.identity_canonical_name(body),
                  responded_at:                 LifecycleEnrichment.recorded_at(body),
                  inserted_at:                  Time.now.utc
                },
                operation:   'lifecycle_persistence.inference_response'
              )
              llm_response_model[response_row_id]
            rescue Sequel::UniqueConstraintViolation => e
              handle_exception(e, level: :debug, handled: true, operation: 'lifecycle_persistence.response_race')
              existing = llm_response_model.first(uuid: response_uuid)
              return LifecycleEnrichment.enrich_response!(existing, response_message, body) if existing

              raise
            end

            def find_or_create_metric(request, response, body)
              metric_uuid = stable_uuid(reference(body, :metric_id, :metric_ref) || "metric:#{request_ref(body)}")
              existing = llm_metric_model.first(uuid: metric_uuid)
              if existing
                LifecycleEnrichment.enrich_metric_context_accounting!(existing, body)
                return existing
              end

              identity_refs = IdentityResolution.caller_identity_refs(body)
              metric_row_id = persist_model(
                model_class: llm_metric_model,
                attrs:       {
                  uuid:                          metric_uuid,
                  message_inference_request_id:  request[:id],
                  message_inference_response_id: response[:id],
                  provider:                      LifecycleEnrichment.provider(body),
                  model_key:                     LifecycleEnrichment.model_id(body),
                  tier:                          LifecycleEnrichment.tier(body),
                  input_tokens:                  LifecycleEnrichment.token_count(body, :input_tokens),
                  output_tokens:                 LifecycleEnrichment.token_count(body, :output_tokens),
                  thinking_tokens:               LifecycleEnrichment.token_count(body, :thinking_tokens),
                  total_tokens:                  LifecycleEnrichment.token_count(body, :total_tokens),
                  latency_ms:                    LifecycleEnrichment.integer(body[:latency_ms]),
                  wall_clock_ms:                 LifecycleEnrichment.integer(body[:wall_clock_ms]),
                  cost_usd:                      LifecycleEnrichment.cost_usd(body),
                  currency:                      body[:currency] || 'USD',
                  cost_center:                   LifecycleEnrichment.billing(body)[:cost_center],
                  budget_key:                    LifecycleEnrichment.billing(body)[:budget_id] || LifecycleEnrichment.billing(body)[:budget_key],
                  identity_principal_id:         identity_refs[:principal_id],
                  identity_id:                   identity_refs[:identity_id],
                  identity_canonical_name:       IdentityResolution.identity_canonical_name(body),
                  recorded_at:                   LifecycleEnrichment.recorded_at(body),
                  inserted_at:                   Time.now.utc
                }.merge(context_accounting_metric_columns(body)),
                operation:   'lifecycle_persistence.inference_metric'
              )
              metric = llm_metric_model[metric_row_id]
              write_context_accounting_events(request, response, metric, body)
              metric
            rescue Sequel::UniqueConstraintViolation => e
              handle_exception(e, level: :debug, handled: true, operation: 'lifecycle_persistence.metric_race')
              existing = llm_metric_model.first(uuid: metric_uuid)
              return LifecycleEnrichment.enrich_metric_context_accounting!(existing, body) if existing

              raise
            end

            def context_accounting_metric_columns(body)
              accounting = LifecycleEnrichment.context_accounting(body)
              {
                request_message_estimated_tokens:      LifecycleEnrichment.token_count(body, :request_message_estimated_tokens),
                loaded_history_estimated_tokens:       LifecycleEnrichment.token_count(body, :loaded_history_estimated_tokens),
                curated_history_estimated_tokens:      LifecycleEnrichment.token_count(body, :curated_history_estimated_tokens),
                curation_saved_estimated_tokens:       LifecycleEnrichment.token_count(body, :curation_saved_estimated_tokens),
                stripped_thinking_estimated_tokens:    LifecycleEnrichment.token_count(body, :stripped_thinking_estimated_tokens),
                archived_history_estimated_tokens:     LifecycleEnrichment.token_count(body, :archived_history_estimated_tokens),
                archive_saved_estimated_tokens:        LifecycleEnrichment.token_count(body, :archive_saved_estimated_tokens),
                context_window_saved_estimated_tokens: LifecycleEnrichment.token_count(body, :context_window_saved_estimated_tokens),
                rag_injected_estimated_tokens:         LifecycleEnrichment.token_count(body, :rag_injected_estimated_tokens),
                system_prompt_estimated_tokens:        LifecycleEnrichment.token_count(body, :system_prompt_estimated_tokens),
                baseline_system_estimated_tokens:      LifecycleEnrichment.token_count(body, :baseline_system_estimated_tokens),
                tool_definition_estimated_tokens:      LifecycleEnrichment.token_count(body, :tool_definition_estimated_tokens),
                final_context_estimated_tokens:        LifecycleEnrichment.token_count(body, :final_context_estimated_tokens),
                loaded_history_message_count:          LifecycleEnrichment.token_count(body, :loaded_history_message_count),
                curated_history_message_count:         LifecycleEnrichment.token_count(body, :curated_history_message_count),
                archived_history_message_count:        LifecycleEnrichment.token_count(body, :archived_history_message_count),
                stripped_thinking_message_count:       LifecycleEnrichment.token_count(body, :stripped_thinking_message_count),
                context_window_message_count_before:   LifecycleEnrichment.token_count(body, :context_window_message_count_before),
                context_window_message_count_after:    LifecycleEnrichment.token_count(body, :context_window_message_count_after),
                rag_entry_count:                       LifecycleEnrichment.token_count(body, :rag_entry_count),
                tool_definition_count:                 LifecycleEnrichment.token_count(body, :tool_definition_count),
                context_accounting_status:             (accounting[:status] || 'missing').to_s,
                context_accounting_json:               accounting.empty? ? nil : LifecycleEnrichment.storage_json_dump(accounting)
              }
            end

            def write_context_accounting_events(request, response, metric, body)
              accounting = LifecycleEnrichment.context_accounting(body)
              return unless accounting.is_a?(Hash)

              events = Array(accounting[:events])
              return if events.empty?

              request_reference = request[:request_ref]
              events.each_with_index do |event, index|
                normalized = event.transform_keys { |key| key.respond_to?(:to_sym) ? key.to_sym : key }
                event_uuid = stable_uuid("context-accounting:#{request_reference}:#{index}:#{normalized[:event_type]}:#{normalized[:component]}")
                next if Legion::Data::Models::LLM::ContextAccountingEvent.first(uuid: event_uuid)

                persist_model(
                  model_class: Legion::Data::Models::LLM::ContextAccountingEvent,
                  attrs:       {
                    uuid:                          event_uuid,
                    message_inference_request_id:  request[:id],
                    message_inference_response_id: response&.[](:id),
                    message_inference_metric_id:   metric&.[](:id),
                    conversation_ref:              body[:conversation_id].to_s,
                    request_ref:                   request_reference,
                    event_type:                    normalized[:event_type].to_s,
                    component:                     normalized[:component].to_s,
                    estimated_tokens_before:       normalized[:estimated_tokens_before].to_i,
                    estimated_tokens_after:        normalized[:estimated_tokens_after].to_i,
                    estimated_tokens_delta:        normalized[:estimated_tokens_delta].to_i,
                    message_count_before:          normalized[:message_count_before].to_i,
                    message_count_after:           normalized[:message_count_after].to_i,
                    metadata_json:                 normalized[:metadata] ? LifecycleEnrichment.json_dump(normalized[:metadata]) : nil,
                    recorded_at:                   LifecycleEnrichment.recorded_at(body),
                    inserted_at:                   Time.now.utc
                  },
                  operation:   'lifecycle_persistence.context_accounting_event'
                )
              end
            rescue StandardError => e
              handle_exception(e, level: :warn, handled: true, operation: 'lifecycle_persistence.context_accounting_events')
            end

            def persist_model(model_class:, attrs:, operation:)
              Helpers::PersistenceLogging.insert_model(
                model_class:    model_class,
                attributes:     attrs,
                operation:      operation,
                warn_on_unique: false
              )
            end

            def next_message_seq(conversation)
              conversation.messages_dataset.max(:seq).to_i + 1
            end

            def request_payload_json(body)
              payload = LifecycleEnrichment.request_payload(body)
              return nil unless payload

              LifecycleEnrichment.phi_protect(
                LifecycleEnrichment.storage_json_dump(payload),
                LifecycleEnrichment.contains_phi?(body)
              )
            end

            def tokens(body)
              raw = body[:tokens] || body
              input = LifecycleEnrichment.integer(raw[:input_tokens] || raw[:input])
              output = LifecycleEnrichment.integer(raw[:output_tokens] || raw[:output])
              thinking = LifecycleEnrichment.integer(raw[:thinking_tokens] || raw[:thinking])
              total = LifecycleEnrichment.integer(raw[:total_tokens] || raw[:total], default: input + output + thinking)

              { input_tokens: input, output_tokens: output, thinking_tokens: thinking, total_tokens: total }
            end

            def classification_level(body)
              allowed = %w[public internal confidential restricted]
              raw = body[:classification_level] || body.dig(:classification, :level)
              normalized = raw.to_s.downcase
              allowed.include?(normalized) ? normalized : 'internal'
            end

            def llm_conversation_model
              ensure_models_loaded!
              Legion::Data::Models::LLM::Conversation
            end

            def llm_message_model
              ensure_models_loaded!
              Legion::Data::Models::LLM::Message
            end

            def llm_request_model
              ensure_models_loaded!
              Legion::Data::Models::LLM::MessageInferenceRequest
            end

            def llm_response_model
              ensure_models_loaded!
              Legion::Data::Models::LLM::MessageInferenceResponse
            end

            def llm_metric_model
              ensure_models_loaded!
              Legion::Data::Models::LLM::MessageInferenceMetric
            end

            def ensure_models_loaded!
              require 'legion/data/model'
              Legion::Data::Models.instance_variable_set(:@loaded_models, []) unless Legion::Data::Models.loaded_models

              missing = []
              missing << 'llm/conversation' unless defined?(Legion::Data::Models::LLM::Conversation)
              missing << 'llm/message' unless defined?(Legion::Data::Models::LLM::Message)
              missing << 'llm/message_inference_request' unless defined?(Legion::Data::Models::LLM::MessageInferenceRequest)
              missing << 'llm/message_inference_response' unless defined?(Legion::Data::Models::LLM::MessageInferenceResponse)
              missing << 'llm/message_inference_metric' unless defined?(Legion::Data::Models::LLM::MessageInferenceMetric)
              missing << 'llm/context_accounting_event' unless defined?(Legion::Data::Models::LLM::ContextAccountingEvent)
              missing << 'llm/route_attempt' unless defined?(Legion::Data::Models::LLM::RouteAttempt)

              Legion::Data::Models.require_sequel_models(missing) unless missing.empty?
            end
          end
        end
      end
    end
  end
end
