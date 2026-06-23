# frozen_string_literal: true

require 'digest'
require 'securerandom'
require 'legion/logging'
require 'legion/data/model'
require 'legion/extensions/llm/responses/thinking_extractor'
require 'legion/settings'
require_relative '../helpers/identity_resolution'

module Legion
  module Extensions
    module Llm
      module Ledger
        module Runners
          # Self-contained lifecycle writer for prompt audit messages.
          # Consumes queue messages from llm.audit.prompts and persists the full
          # lifecycle: conversation -> user message -> request -> response message
          # -> response -> metric -> route attempts -> context accounting events.
          module Prompts
            extend self
            extend Legion::Logging::Helper

            ALLOWED_CLASSIFICATION_LEVELS = %w[public internal confidential restricted].freeze
            CONTEXT_ACCOUNTING_STATUS_RANK = {
              'missing' => 0, 'profile_skipped' => 1, 'partial' => 2,
              'estimated' => 3, 'provider_reconciled' => 4
            }.freeze
            RETENTION_MAP = { 'session_only' => 0, 'days_30' => 30, 'days_90' => 90, 'permanent' => nil }.freeze
            PHI_TTL_DAYS = 30
            DEFAULT_RETENTION_DAYS = 90

            # ─── Public API ────────────────────────────────────────────────

            # Full lifecycle write from audit.prompt queue.
            def insert(payload:, metadata: {}, **)
              headers = metadata[:headers] || {}
              body = resolve_body(payload, metadata)
              body = merge_official_fields(body, metadata, headers)

              conversation = find_or_create_conversation(body, headers)
              user_message = find_or_create_user_message(conversation, body, headers)
              request = find_or_create_request(conversation, user_message, body, headers)
              response_message = find_or_create_response_message(conversation, request, body, headers)
              response = find_or_create_response(request, response_message, body, headers)
              link_response_message!(response_message, response)
              metric = find_or_create_metric(request, response, body)
              write_route_attempts(request, response, body)
              write_context_accounting_events(request, response, metric, body)
              { result: :ok, request_id: request[:id], response_id: response[:id], metric_id: metric[:id] }
            end

            # Metering subset: conversation -> request -> response -> metric (NO messages).
            # Called by the Metering runner.
            def write_metering(payload:, metadata: {}, **)
              headers = metadata[:headers] || {}
              body = resolve_body(payload, metadata)
              body = merge_official_fields(body, metadata, headers)

              conversation = find_or_create_conversation(body, headers)
              request = find_or_create_request(conversation, nil, body, headers)
              response = find_or_create_response(request, nil, body, headers)
              metric = find_or_create_metric(request, response, body)
              write_route_attempts(request, response, body)
              { result: :ok, request_id: request[:id], response_id: response[:id], metric_id: metric[:id] }
            end

            # FK backfill: link a response message row to an inference response row.
            def link(response_message_id:, response_id:, **)
              return { result: :ok } unless response_message_id && response_id

              message = Runners::Messages.fetch(id: response_message_id)
              return { result: :ok } unless message && message[:message_inference_response_id] != response_id

              message.update(message_inference_response_id: response_id)
              { result: :ok }
            rescue StandardError => e
              handle_exception(e, level: :warn, handled: true, operation: 'prompts.link')
              { result: :ok }
            end

            private

            # rubocop:disable Legion/Extension/RunnerReturnHash

            # ─── Body Resolution ───────────────────────────────────────────

            def resolve_body(payload, _metadata)
              payload.is_a?(Hash) ? payload : {}
            end

            def merge_official_fields(body, metadata, headers)
              body.merge(
                resolve_context_fields(body, metadata, headers),
                resolve_compliance_fields(body, headers)
              )
            end

            def resolve_context_fields(body, metadata, headers)
              props = metadata[:properties] || {}
              ctx = body[:message_context] || {}
              routing = body[:routing] || {}
              {
                message_id:          props[:message_id] || body[:message_id] || ctx[:message_id],
                correlation_id:      props[:correlation_id] || body[:correlation_id],
                conversation_id:     ctx[:conversation_id] || body[:conversation_id] || headers['x-legion-llm-conversation-id'],
                response_message_id: body[:response_message_id],
                request_id:          ctx[:request_id] || body[:request_id] || headers['x-legion-llm-request-id'],
                exchange_id:         ctx[:exchange_id] || body[:exchange_id],
                operation:           body[:operation] || body[:request_type] || headers['x-legion-llm-request-type'],
                provider:            routing[:provider] || body[:provider] || headers['x-legion-llm-provider'],
                provider_instance:   routing[:provider_instance] || routing[:instance] || body[:provider_instance],
                model_id:            routing[:model] || body[:model_id] || headers['x-legion-llm-model'],
                tier:                routing[:tier] || body[:tier] || headers['x-legion-llm-tier']
              }
            end

            def resolve_compliance_fields(body, headers)
              is_phi = headers['x-legion-contains-phi'] == 'true' || body.dig(:classification, :contains_phi) || false
              {
                retention_policy:     headers['x-legion-retention'] || body[:retention_policy],
                expires_at:           resolve_expires_at(headers: headers, body: body),
                contains_phi:         is_phi,
                contains_pii:         body.dig(:classification, :contains_pii) ? true : false,
                classification_level: classification_level(body)
              }
            end

            # ─── TTL / Retention ───────────────────────────────────────────

            def resolve_expires_at(headers:, body:)
              resolve_retention_expires_at(
                headers['x-legion-retention'],
                headers['x-legion-contains-phi'] == 'true' || body.dig(:classification, :contains_phi) || false
              )
            end

            def resolve_retention_expires_at(retention_label, contains_phi)
              label = retention_label.to_s.empty? ? 'default' : retention_label.to_s
              days = label == 'default' ? DEFAULT_RETENTION_DAYS : RETENTION_MAP.fetch(label, DEFAULT_RETENTION_DAYS)
              days = [days, PHI_TTL_DAYS].compact.min if contains_phi
              days ? Time.now.utc + (days * 86_400) : nil
            end

            # ─── Lifecycle Persistence ─────────────────────────────────────

            def find_or_create_conversation(body, _headers)
              uuid = stable_uuid(reference(body, :conversation_id) || 'default-conversation')
              Runners::Conversations.find_or_create(
                uuid:  uuid,
                attrs: {
                  title:                   body[:title] || body[:conversation_title],
                  classification_level:    classification_level(body),
                  contains_phi:            body[:contains_phi] || false,
                  contains_pii:            body[:contains_pii] || false,
                  pii_types_json:          json_dump(Array(body.dig(:classification, :pii_types))),
                  jurisdictions_json:      json_dump(Array(body.dig(:classification, :jurisdictions) || body[:jurisdictions])),
                  retention_policy:        body[:retention_policy] || 'default',
                  expires_at:              body[:expires_at],
                  identity_canonical_name: Helpers::IdentityResolution.canonical_name(body: body, headers: {}),
                  recorded_at:             recorded_at(body),
                  inserted_at:             Time.now.utc,
                  created_at:              Time.now.utc,
                  updated_at:              Time.now.utc
                }
              )
            end

            def find_or_create_user_message(conversation, body, _headers)
              uuid = stable_uuid(reference(body, :message_id) || "request-message:#{request_ref(body)}")
              seq = body[:message_seq] ? integer(body[:message_seq]) : next_message_seq(conversation)
              identity_refs = Helpers::IdentityResolution.resolve_refs(body: body, headers: {})
              Runners::Messages.find_or_create(
                uuid:  uuid,
                attrs: {
                  conversation_id:         conversation[:id],
                  seq:                     seq,
                  role:                    'user',
                  content_type:            'text',
                  content:                 request_content(body),
                  input_tokens:            tokens(body)[:input_tokens],
                  output_tokens:           0,
                  identity_principal_id:   identity_refs[:principal_id],
                  identity_id:             identity_refs[:identity_id],
                  identity_canonical_name: Helpers::IdentityResolution.canonical_name(body: body, headers: {}),
                  created_at:              recorded_at(body),
                  inserted_at:             Time.now.utc
                }
              )
            end

            def find_or_create_request(conversation, latest_message, body, _headers)
              ref = request_ref(body)
              existing = Runners::Requests.fetch(ref: ref)
              return enrich_request!(existing, body, latest_message) if existing

              op = operation(body)
              identity_refs = Helpers::IdentityResolution.resolve_refs(body: body, headers: {})
              record = Runners::Requests.find_or_create(
                uuid:  stable_uuid(ref),
                attrs: {
                  conversation_id:         conversation[:id],
                  latest_message_id:       latest_message&.[](:id),
                  parent_request_id:       resolve_parent_request_id(body),
                  caller_principal_id:     identity_refs[:principal_id],
                  caller_identity_id:      identity_refs[:identity_id],
                  identity_canonical_name: Helpers::IdentityResolution.canonical_name(body: body, headers: {}),
                  runtime_caller_type:     caller_type(body),
                  runtime_caller_class:    runtime_caller_class(body),
                  runtime_caller_client:   runtime_caller_client(body),
                  request_ref:             ref,
                  correlation_ref:         correlation_id(body),
                  correlation_id:          correlation_id(body),
                  exchange_ref:            body[:exchange_id],
                  request_type:            op,
                  operation:               op,
                  idempotency_key:         body[:idempotency_key] || ref,
                  status:                  'responded',
                  context_message_count:   Array(body.dig(:request, :messages) || body[:messages]).size,
                  request_capture_mode:    'full',
                  request_json:            request_payload_json(body),
                  classification_level:    classification_level(body),
                  cost_center:             billing(body)[:cost_center],
                  budget_key:              billing(body)[:budget_id] || billing(body)[:budget_key],
                  injected_tool_count:     Array(body.dig(:audit, :injected_tools) || body[:injected_tools]).size,
                  context_tokens:          body[:context_tokens] || body.dig(:tokens, :context_tokens),
                  request_content_hash:    resolve_request_content_hash(body),
                  curation_strategy:       body[:curation_strategy] || body.dig(:audit, :curation_strategy),
                  tool_policy:             body[:tool_policy] || body.dig(:audit, :tool_policy),
                  requested_at:            recorded_at(body),
                  inserted_at:             Time.now.utc
                }
              )
              # If find_or_create returned a pre-existing record (race), enrich it
              enrich_request!(record, body, latest_message)
            end

            def find_or_create_response_message(conversation, request, body, _headers)
              uuid = stable_uuid(reference(body, :response_message_id) || "response-message:#{request_ref(body)}")
              latest = Runners::Messages.fetch(id: request[:latest_message_id])
              seq = (latest&.[](:seq) || 1) + 1
              identity_refs = Helpers::IdentityResolution.resolve_refs(body: body, headers: {})
              Runners::Messages.find_or_create(
                uuid:  uuid,
                attrs: {
                  conversation_id:              conversation[:id],
                  parent_message_id:            latest&.[](:id),
                  message_inference_request_id: request[:id],
                  seq:                          seq,
                  role:                         'assistant',
                  content_type:                 'text',
                  content:                      response_content(body),
                  input_tokens:                 0,
                  output_tokens:                token_count(body, :output_tokens),
                  identity_principal_id:        identity_refs[:principal_id],
                  identity_id:                  identity_refs[:identity_id],
                  identity_canonical_name:      Helpers::IdentityResolution.canonical_name(body: body, headers: {}),
                  created_at:                   recorded_at(body),
                  inserted_at:                  Time.now.utc
                }
              )
            end

            def find_or_create_response(request, response_message, body, _headers)
              response_ref = reference(body, :provider_response_ref) ||
                             "response:#{request_ref(body)}:#{provider(body).to_s.empty? ? 'unknown' : provider(body)}"
              response_uuid = stable_uuid(response_ref)
              existing = Runners::Responses.fetch(uuid: response_uuid)
              existing ||= Runners::Responses.fetch(request_id: request[:id])

              if existing
                enrich_response!(existing, response_message, body)
                return existing
              end

              vis = visible_response(body)
              thinking = thinking_response(body)
              is_phi = body[:contains_phi] || false
              identity_refs = Helpers::IdentityResolution.resolve_refs(body: body, headers: {})

              record = Runners::Responses.find_or_create(
                uuid:  response_uuid,
                attrs: {
                  message_inference_request_id: request[:id],
                  response_message_id:          response_message&.[](:id),
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
                  response_json:                vis ? phi_protect(storage_json_dump(vis), is_phi) : nil,
                  response_thinking_json:       thinking ? phi_protect(storage_json_dump(thinking), is_phi) : nil,
                  dispatch_path:                body[:dispatch_path] || body[:tier],
                  error_category:               body[:error_category] || body.dig(:error, :category),
                  error_code:                   body[:error_code] || body.dig(:error, :code),
                  error_message:                body[:error_message] || body.dig(:error, :message),
                  response_content_hash:        resolve_response_content_hash(body),
                  route_attempts:               (body[:route_attempts] || body.dig(:audit, :route_attempts)).to_i,
                  escalation_chain_ref:         body[:escalation_chain_ref],
                  identity_principal_id:        identity_refs[:principal_id],
                  identity_id:                  identity_refs[:identity_id],
                  identity_canonical_name:      Helpers::IdentityResolution.canonical_name(body: body, headers: {}),
                  responded_at:                 recorded_at(body),
                  inserted_at:                  Time.now.utc
                }
              )
              # If find_or_create returned a pre-existing record (race), enrich it
              enrich_response!(record, response_message, body)
              record
            end

            def find_or_create_metric(request, response, body)
              metric_uuid = stable_uuid(reference(body, :metric_id, :metric_ref) || "metric:#{request_ref(body)}")
              existing = Runners::Metrics.fetch(uuid: metric_uuid)
              if existing
                enrich_metric_context_accounting!(existing, body)
                return existing
              end

              identity_refs = Helpers::IdentityResolution.resolve_refs(body: body, headers: {})
              record = Runners::Metrics.find_or_create(
                uuid:  metric_uuid,
                attrs: {
                  message_inference_request_id:  request[:id],
                  message_inference_response_id: response[:id],
                  provider:                      provider(body),
                  model_key:                     model_id(body),
                  tier:                          tier(body),
                  input_tokens:                  token_count(body, :input_tokens),
                  output_tokens:                 token_count(body, :output_tokens),
                  thinking_tokens:               token_count(body, :thinking_tokens),
                  total_tokens:                  token_count(body, :total_tokens),
                  latency_ms:                    integer(body[:latency_ms]),
                  wall_clock_ms:                 integer(body[:wall_clock_ms]),
                  cost_usd:                      cost_usd(body),
                  currency:                      body[:currency] || 'USD',
                  cost_center:                   billing(body)[:cost_center],
                  budget_key:                    billing(body)[:budget_id] || billing(body)[:budget_key],
                  identity_principal_id:         identity_refs[:principal_id],
                  identity_id:                   identity_refs[:identity_id],
                  identity_canonical_name:       Helpers::IdentityResolution.canonical_name(body: body, headers: {}),
                  recorded_at:                   recorded_at(body),
                  inserted_at:                   Time.now.utc
                }.merge(context_accounting_metric_columns(body))
              )
              enrich_metric_context_accounting!(record, body)
              record
            end

            # ─── Enrichment ────────────────────────────────────────────────

            def enrich_request!(existing, body, latest_message = nil)
              updates = {}
              update_if_missing(updates, existing, :latest_message_id, latest_message&.[](:id))
              update_if_missing(updates, existing, :runtime_caller_class, runtime_caller_class(body))
              update_if_missing(updates, existing, :runtime_caller_client, runtime_caller_client(body))
              update_if_missing(updates, existing, :identity_canonical_name, Helpers::IdentityResolution.canonical_name(body: body, headers: {}))
              update_if_missing(updates, existing, :request_content_hash, resolve_request_content_hash(body))

              rj = request_payload(body) ? storage_json_dump(request_payload(body)) : nil
              update_if_placeholder(updates, existing, :request_json, rj)

              return existing if updates.empty?

              existing.update(updates)
              existing
            end

            def enrich_response!(existing, response_message, body)
              updates = {}
              update_if_missing(updates, existing, :response_message_id, response_message&.[](:id))
              update_if_missing(updates, existing, :tier, tier(body))
              update_if_missing(updates, existing, :provider_instance, provider_instance(body))
              update_if_missing(updates, existing, :finish_reason, finish_reason(body))
              update_if_missing(updates, existing, :dispatch_path, body[:dispatch_path] || body[:tier])
              update_if_missing(updates, existing, :identity_canonical_name, Helpers::IdentityResolution.canonical_name(body: body, headers: {}))
              update_if_missing(updates, existing, :response_content_hash, resolve_response_content_hash(body))

              vis = visible_response(body)
              update_if_placeholder(updates, existing, :response_json, storage_json_dump(vis)) if vis

              think = thinking_response(body)
              update_if_placeholder(updates, existing, :response_thinking_json, storage_json_dump(think)) if think

              return existing if updates.empty?

              existing.update(updates)
              existing
            end

            def enrich_metric_context_accounting!(existing, body)
              incoming = context_accounting(body)
              return existing if incoming.empty?

              incoming_status = (incoming[:status] || 'missing').to_s
              existing_status = (existing[:context_accounting_status] || 'missing').to_s
              return existing unless richer_context_accounting?(existing_status, incoming_status)

              token_accounting = incoming[:tokens] || {}
              count_accounting = incoming[:counts] || {}
              updates = {
                request_message_estimated_tokens:      integer(token_accounting[:request_message_estimated_tokens]),
                loaded_history_estimated_tokens:       integer(token_accounting[:loaded_history_estimated_tokens]),
                curated_history_estimated_tokens:      integer(token_accounting[:curated_history_estimated_tokens]),
                curation_saved_estimated_tokens:       integer(token_accounting[:curation_saved_estimated_tokens]),
                stripped_thinking_estimated_tokens:    integer(token_accounting[:stripped_thinking_estimated_tokens]),
                archived_history_estimated_tokens:     integer(token_accounting[:archived_history_estimated_tokens]),
                archive_saved_estimated_tokens:        integer(token_accounting[:archive_saved_estimated_tokens]),
                context_window_saved_estimated_tokens: integer(token_accounting[:context_window_saved_estimated_tokens]),
                rag_injected_estimated_tokens:         integer(token_accounting[:rag_injected_estimated_tokens]),
                system_prompt_estimated_tokens:        integer(token_accounting[:system_prompt_estimated_tokens]),
                baseline_system_estimated_tokens:      integer(token_accounting[:baseline_system_estimated_tokens]),
                tool_definition_estimated_tokens:      integer(token_accounting[:tool_definition_estimated_tokens]),
                final_context_estimated_tokens:        integer(token_accounting[:final_context_estimated_tokens]),
                loaded_history_message_count:          integer(count_accounting[:loaded_history_message_count]),
                curated_history_message_count:         integer(count_accounting[:curated_history_message_count]),
                archived_history_message_count:        integer(count_accounting[:archived_history_message_count]),
                stripped_thinking_message_count:       integer(count_accounting[:stripped_thinking_message_count]),
                context_window_message_count_before:   integer(count_accounting[:context_window_message_count_before]),
                context_window_message_count_after:    integer(count_accounting[:context_window_message_count_after]),
                rag_entry_count:                       integer(count_accounting[:rag_entry_count]),
                tool_definition_count:                 integer(count_accounting[:tool_definition_count]),
                context_accounting_status:             incoming_status,
                context_accounting_json:               storage_json_dump(incoming)
              }
              existing.update(updates)
              existing
            rescue StandardError => e
              handle_exception(e, level: :warn, handled: true, operation: 'prompts.context_accounting_enrich')
              existing
            end

            # ─── Route Attempts ────────────────────────────────────────────

            def write_route_attempts(request, response, body)
              attempts = Array(body[:route_attempt_details])
              return if attempts.empty?

              identity_refs = Helpers::IdentityResolution.resolve_refs(body: body, headers: {})
              attempts.each_with_index do |attempt, idx|
                next unless attempt.is_a?(Hash)

                attempt_no = (attempt[:attempt_no] || (idx + 1)).to_i
                uuid = stable_uuid("#{request[:uuid]}:attempt:#{attempt_no}")

                Runners::RouteAttempts.insert(
                  uuid:  uuid,
                  attrs: {
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
                    identity_principal_id:         identity_refs[:principal_id],
                    identity_id:                   identity_refs[:identity_id],
                    identity_canonical_name:       Helpers::IdentityResolution.canonical_name(body: body, headers: {}),
                    inserted_at:                   Time.now.utc
                  }
                )
              end
            rescue StandardError => e
              handle_exception(e, level: :warn, handled: true, operation: 'prompts.route_attempts')
            end

            # ─── Context Accounting Events ─────────────────────────────────

            def write_context_accounting_events(request, response, metric, body)
              accounting = context_accounting(body)
              return unless accounting.is_a?(Hash)

              events = Array(accounting[:events])
              return if events.empty?

              request_reference = request[:request_ref]
              events.each_with_index do |event, index|
                normalized = event.transform_keys { |key| key.respond_to?(:to_sym) ? key.to_sym : key }
                event_uuid = stable_uuid("context-accounting:#{request_reference}:#{index}:#{normalized[:event_type]}:#{normalized[:component]}")

                Runners::ContextAccountingEvents.insert(
                  uuid:  event_uuid,
                  attrs: {
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
                    metadata_json:                 normalized[:metadata] ? json_dump(normalized[:metadata]) : nil,
                    recorded_at:                   recorded_at(body),
                    inserted_at:                   Time.now.utc
                  }
                )
              end
            rescue StandardError => e
              handle_exception(e, level: :warn, handled: true, operation: 'prompts.context_accounting_events')
            end

            # ─── Link Helper ───────────────────────────────────────────────

            def link_response_message!(response_message, response)
              return unless response_message && response
              return if response_message[:message_inference_response_id] == response[:id]

              response_message.update(message_inference_response_id: response[:id])
            end

            # ─── Stable Identifiers ────────────────────────────────────────

            def stable_uuid(value)
              raw = value.to_s
              return raw if raw.length <= 36

              hex = Digest::SHA256.hexdigest(raw)[0, 32]
              "#{hex[0, 8]}-#{hex[8, 4]}-#{hex[12, 4]}-#{hex[16, 4]}-#{hex[20, 12]}"
            end

            # ─── Request Ref ───────────────────────────────────────────────

            def request_ref(body)
              body[:__ledger_request_ref] ||=
                reference(body, :request_id, :request_ref) ||
                correlation_id(body) ||
                (body[:__ledger_generated_request_ref] ||= SecureRandom.uuid)
            end

            # ─── Field Extractors ──────────────────────────────────────────

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

            def operation(body)
              (body[:operation] || body[:request_type] || body.dig(:routing, :operation) ||
                body.dig(:headers, :'x-legion-llm-request-type') || 'chat').to_s
            end

            def correlation_id(body)
              reference(body, :correlation_id, :correlation_ref) || body.dig(:tracing, :correlation_id)
            end

            def tokens(body)
              raw = body[:tokens] || body
              input = integer(raw[:input_tokens] || raw[:input])
              output = integer(raw[:output_tokens] || raw[:output])
              thinking = integer(raw[:thinking_tokens] || raw[:thinking])
              total = integer(raw[:total_tokens] || raw[:total], default: input + output + thinking)
              { input_tokens: input, output_tokens: output, thinking_tokens: thinking, total_tokens: total }
            end

            def token_count(body, key)
              raw = body[:tokens] || body
              lookup_key = key.to_sym
              aliases = { input_tokens: :input, output_tokens: :output, thinking_tokens: :thinking, total_tokens: :total }
              integer(raw[lookup_key] || raw[aliases[lookup_key]])
            end

            def cost_usd(body)
              raw = body[:cost_usd] || body.dig(:cost, :estimated_usd) || body.dig(:cost, :usd)
              raw.to_f
            end

            def billing(body)
              body[:billing] || body[:cost] || {}
            end

            def finish_reason(body)
              return body[:finish_reason] if body[:finish_reason]
              return nil unless body[:response].is_a?(Hash)

              body.dig(:response, :finish_reason) || body.dig(:response, :stop, :reason)
            end

            def classification_level(body)
              raw = body[:classification_level] || body.dig(:classification, :level)
              return 'internal' if raw.nil? || raw.to_s.empty?

              normalized = raw.to_s.downcase
              ALLOWED_CLASSIFICATION_LEVELS.include?(normalized) ? normalized : 'internal'
            end

            def caller_type(body)
              raw_type = body[:caller_type] ||
                         body.dig(:identity, :type) ||
                         body.dig(:caller, :requested_by, :type) ||
                         body.dig(:caller, :source)
              return Helpers::IdentityResolution.normalize_caller(body: body, headers: {})[:type] if present?(raw_type)

              nil
            end

            def runtime_caller_class(body)
              body.dig(:caller, :class) || body.dig(:caller, :caller_class) ||
                body.dig(:caller, :source_class) || body[:runtime_caller_class]
            end

            def runtime_caller_client(body)
              body.dig(:caller, :client) || body.dig(:caller, :user_agent) ||
                body[:runtime_caller_client]
            end

            def recorded_at(body)
              body[:recorded_at] || body[:timestamp] || body.dig(:timestamps, :returned) ||
                body.dig(:timestamps, :provider_end) || Time.now.utc
            end

            # ─── Response Extraction ───────────────────────────────────────

            def visible_response(body)
              response = body[:response] || body[:response_content] || body[:content]
              return nil if response.nil? || (response.is_a?(Hash) && response.empty?)

              if response.is_a?(String)
                clean, _thinking = extract_inline_thinking(response)
                return { content: clean }
              end
              return { content: response[:content] } if response.is_a?(Hash) && response.key?(:content)

              response.is_a?(Hash) ? response.except(:thinking) : { content: response.to_s }
            end

            def thinking_response(body)
              thinking = body[:response_thinking] || body[:thinking]
              thinking ||= body.dig(:response, :thinking) if body[:response].is_a?(Hash)
              if thinking
                return { content: thinking } if thinking.is_a?(String)

                return thinking
              end

              content_str = body[:response_content] || body[:response] || body[:content]
              return nil unless content_str.is_a?(String)

              _clean, extracted = extract_inline_thinking(content_str)
              extracted ? { content: extracted } : nil
            end

            def response_content(body)
              vis = visible_response(body)
              return nil unless vis

              stringify_content(vis[:content] || vis.dig(:message, :content))
            end

            def request_content(body)
              messages = body.dig(:request, :messages) || body[:messages]
              message = Array(messages).reverse.find { |item| item[:role].to_s == 'user' } || Array(messages).last
              content = message&.dig(:content) || body[:prompt] || body[:text]
              stringify_content(content)
            end

            def request_payload(body)
              body[:request] || body[:messages]
            end

            # ─── Context Accounting ────────────────────────────────────────

            def context_accounting(body)
              raw = body[:context_accounting] || body.dig(:audit, :context_accounting)
              raw.is_a?(Hash) ? raw : {}
            end

            def context_accounting_metric_columns(body)
              accounting = context_accounting(body)
              {
                request_message_estimated_tokens:      token_count(body, :request_message_estimated_tokens),
                loaded_history_estimated_tokens:       token_count(body, :loaded_history_estimated_tokens),
                curated_history_estimated_tokens:      token_count(body, :curated_history_estimated_tokens),
                curation_saved_estimated_tokens:       token_count(body, :curation_saved_estimated_tokens),
                stripped_thinking_estimated_tokens:    token_count(body, :stripped_thinking_estimated_tokens),
                archived_history_estimated_tokens:     token_count(body, :archived_history_estimated_tokens),
                archive_saved_estimated_tokens:        token_count(body, :archive_saved_estimated_tokens),
                context_window_saved_estimated_tokens: token_count(body, :context_window_saved_estimated_tokens),
                rag_injected_estimated_tokens:         token_count(body, :rag_injected_estimated_tokens),
                system_prompt_estimated_tokens:        token_count(body, :system_prompt_estimated_tokens),
                baseline_system_estimated_tokens:      token_count(body, :baseline_system_estimated_tokens),
                tool_definition_estimated_tokens:      token_count(body, :tool_definition_estimated_tokens),
                final_context_estimated_tokens:        token_count(body, :final_context_estimated_tokens),
                loaded_history_message_count:          token_count(body, :loaded_history_message_count),
                curated_history_message_count:         token_count(body, :curated_history_message_count),
                archived_history_message_count:        token_count(body, :archived_history_message_count),
                stripped_thinking_message_count:       token_count(body, :stripped_thinking_message_count),
                context_window_message_count_before:   token_count(body, :context_window_message_count_before),
                context_window_message_count_after:    token_count(body, :context_window_message_count_after),
                rag_entry_count:                       token_count(body, :rag_entry_count),
                tool_definition_count:                 token_count(body, :tool_definition_count),
                context_accounting_status:             (accounting[:status] || 'missing').to_s,
                context_accounting_json:               accounting.empty? ? nil : storage_json_dump(accounting)
              }
            end

            # ─── Upsert Guards ─────────────────────────────────────────────

            def update_if_missing(updates, existing, key, value)
              updates[key] = value if existing[key].nil? && upsert_guard?(value)
            end

            def update_if_placeholder(updates, existing, key, value)
              return unless upsert_guard?(value)

              existing_val = existing[key]
              is_placeholder = ['{}', 'null'].include?(existing_val.to_s)
              updates[key] = value if is_placeholder
            end

            def upsert_guard?(value)
              return false if value.nil?
              return false if value.is_a?(String) && value.strip.empty?
              return false if value.to_s == '{}'

              true
            end

            def richer_context_accounting?(existing_status, incoming_status)
              CONTEXT_ACCOUNTING_STATUS_RANK.fetch(incoming_status, 0) >=
                CONTEXT_ACCOUNTING_STATUS_RANK.fetch(existing_status, 0)
            end

            # ─── Content Hashing ───────────────────────────────────────────

            def resolve_request_content_hash(body)
              return body[:request_content_hash] if present?(body[:request_content_hash])

              compute_content_hash(body.dig(:request, :content) || body.dig(:audit, :request_content))
            end

            def resolve_response_content_hash(body)
              return body[:response_content_hash] if present?(body[:response_content_hash])

              compute_content_hash(body[:response_content] || body.dig(:audit, :response_content))
            end

            def compute_content_hash(content)
              return nil if content.nil? || content.to_s.empty?

              Digest::SHA256.hexdigest(json_dump(content))[0..31]
            end

            # ─── Parent Request Resolution ─────────────────────────────────

            def resolve_parent_request_id(body)
              parent_ref = body[:parent_request_id] || body.dig(:context, :parent_request_id) ||
                           body.dig(:caller, :parent_request_ref)
              return nil unless present?(parent_ref)

              if parent_ref.is_a?(Integer)
                parent_ref
              else
                parent = Runners::Requests.fetch(ref: parent_ref.to_s)
                parent&.[](:id)
              end
            end

            # ─── PHI Protection ────────────────────────────────────────────

            def phi_protect(json_string, is_phi)
              return json_string unless is_phi && crypt_available?

              Legion::Crypt.encrypt(json_string)
            rescue StandardError => e
              handle_exception(e, level: :warn, handled: true, operation: 'prompts.phi_encrypt')
              json_string
            end

            def crypt_available?
              defined?(Legion::Crypt) && Legion::Crypt.respond_to?(:encrypt)
            end

            # ─── Thinking Extraction ───────────────────────────────────────

            def extract_inline_thinking(text)
              extraction = Legion::Extensions::Llm::Responses::ThinkingExtractor.extract(text)
              [extraction.content, extraction.thinking]
            end

            # ─── JSON / String Utilities ───────────────────────────────────

            def json_dump(value)
              Legion::JSON.dump(value) # rubocop:disable Legion/HelperMigration/DirectJson
            end

            def storage_json_dump(value)
              Legion::JSON.dump(value) # rubocop:disable Legion/HelperMigration/DirectJson
            end

            def stringify_content(content)
              return nil if content.nil?
              return content if content.is_a?(String)

              json_dump(content)
            end

            def request_payload_json(body)
              payload = request_payload(body)
              return nil unless payload

              is_phi = body[:contains_phi] || false
              phi_protect(storage_json_dump(payload), is_phi)
            end

            # ─── Sequence / Utility ────────────────────────────────────────

            def next_message_seq(conversation)
              conversation.messages_dataset.max(:seq).to_i + 1
            end

            def reference(body, *keys)
              keys.lazy.map { |key| body[key] }.find { |value| present?(value) }&.to_s
            end

            def present?(value)
              !value.nil? && !(value.respond_to?(:empty?) && value.empty?)
            end

            def integer(value, default: 0)
              return default if value.nil?

              value.to_i
            end

            # ─── Legacy Interface Support ──────────────────────────────────
            # These methods preserve the old runner's interface so existing specs
            # that test private methods via .send still pass.

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

            def official_identity_payload(body, headers)
              normalized = Helpers::IdentityResolution.normalize_caller(body: body, headers: headers)
              {
                caller_identity:       normalized[:identity],
                caller_type:           normalized[:type],
                __header_principal_id: normalized[:principal_id],
                __header_identity_id:  normalized[:identity_id]
              }.compact
            end

            # rubocop:enable Legion/Extension/RunnerReturnHash

            include Legion::Extensions::Helpers::Lex if Legion::Extensions.const_defined?(:Helpers, false) &&
                                                        Legion::Extensions::Helpers.const_defined?(:Lex, false)
          end
        end
      end
    end
  end
end
