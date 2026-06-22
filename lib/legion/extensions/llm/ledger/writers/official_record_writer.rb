# frozen_string_literal: true

require 'digest'
require 'securerandom'
require 'legion/logging'
require 'legion/extensions/llm/responses/thinking_extractor'
require_relative '../helpers/json'
require_relative '../helpers/persistence_logging'
require_relative 'official_route_attempt_writer'

module Legion
  module Extensions
    module Llm
      module Ledger
        module Writers
          module OfficialRecordWriter
            extend Legion::Logging::Helper

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
                OfficialRouteAttemptWriter.write_route_attempts(db, request, response, body)
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
                request = find_or_create_request(db, conversation, nil, body)
                response = find_or_create_response(db, request, nil, body)
                metric = find_or_create_metric(db, request, response, body)
                OfficialRouteAttemptWriter.write_route_attempts(db, request, response, body)
                result = { result: :ok, request_id: request[:id], response_id: response[:id], metric_id: metric[:id] }
              end

              result
            end

            def find_or_create_conversation(db, body)
              uuid = stable_uuid(reference(body, :conversation_id, :conversation_ref) || 'default-conversation')
              existing = llm_conversation_model.first(uuid: uuid)
              return existing if existing

              id = insert_with_savepoint(db, :llm_conversations, {
                                           uuid:                    uuid,
                                           title:                   body[:title] || body[:conversation_title],
                                           classification_level:    classification_level(body),
                                           contains_phi:            contains_phi?(body),
                                           contains_pii:            contains_pii?(body),
                                           pii_types_json:          json_dump(Array(body.dig(:classification, :pii_types))),
                                           jurisdictions_json:      json_dump(Array(body.dig(:classification, :jurisdictions) || body[:jurisdictions])),
                                           retention_policy:        body[:retention_policy] || 'default',
                                           expires_at:              body[:expires_at],
                                           identity_canonical_name: identity_canonical_name(body),
                                           recorded_at:             recorded_at(body),
                                           inserted_at:             Time.now.utc,
                                           created_at:              Time.now.utc,
                                           updated_at:              Time.now.utc
                                         }, operation: 'official_record_writer.conversation')
              llm_conversation_model[id]
            rescue Sequel::UniqueConstraintViolation => e
              log.debug("[ledger] conversation collision resolved uuid=#{uuid} error=#{e.class}")
              existing = llm_conversation_model.first(uuid: uuid)
              return existing if existing

              raise
            end

            def find_or_create_user_message(db, conversation, body)
              uuid = stable_uuid(reference(body, :message_id, :message_id_ctx) || "request-message:#{request_ref(body)}")
              existing = llm_message_model.first(uuid: uuid)
              return existing if existing

              seq = body[:message_seq] ? integer(body[:message_seq]) : next_message_seq(db, conversation)
              begin
                id = insert_with_savepoint(db, :llm_messages, {
                                             uuid:                    uuid,
                                             conversation_id:         conversation[:id],
                                             seq:                     seq,
                                             role:                    'user',
                                             content_type:            'text',
                                             content:                 request_content(body),
                                             input_tokens:            tokens(body)[:input_tokens],
                                             output_tokens:           0,
                                             identity_principal_id:   caller_identity_refs(db, body)[:principal_id],
                                             identity_id:             caller_identity_refs(db, body)[:identity_id],
                                             identity_canonical_name: identity_canonical_name(body),
                                             created_at:              recorded_at(body),
                                             inserted_at:             Time.now.utc
                                           }, operation: 'official_record_writer.user_message')
                llm_message_model[id]
              rescue Sequel::UniqueConstraintViolation => e
                log.debug("[ledger] seq collision resolved uuid=#{uuid} conversation_id=#{conversation[:id]} error=#{e.class}")
                llm_message_model.first(uuid: uuid) ||
                  llm_message_model.first(conversation_id: conversation[:id], seq: seq)
              end
            end

            def find_or_create_request(db, conversation, latest_message, body)
              request_id = request_ref(body)
              existing = llm_request_model.lookup(request_id)
              return enrich_request!(db, existing, body, latest_message) if existing

              operation = operation(body)
              caller_refs = caller_identity_refs(db, body)
              id = insert_with_savepoint(db, :llm_message_inference_requests, {
                                           uuid:                    stable_uuid(request_id),
                                           conversation_id:         conversation[:id],
                                           latest_message_id:       latest_message&.[](:id),
                                           parent_request_id:       resolve_parent_request_id(db, body),
                                           caller_principal_id:     caller_refs[:principal_id],
                                           caller_identity_id:      caller_refs[:identity_id],
                                           identity_canonical_name: identity_canonical_name(body),
                                           runtime_caller_type:     caller_type(body),
                                           runtime_caller_class:    runtime_caller_class(body),
                                           runtime_caller_client:   runtime_caller_client(body),
                                           request_ref:             request_id,
                                           correlation_ref:         correlation_id(body),
                                           correlation_id:          correlation_id(body),
                                           exchange_ref:            body[:exchange_id],
                                           request_type:            operation,
                                           operation:               operation,
                                           idempotency_key:         body[:idempotency_key] || request_id,
                                           status:                  'responded',
                                           context_message_count:   Array(body.dig(:request, :messages) || body[:messages]).size,
                                           request_capture_mode:    'full',
                                           request_json:            if request_payload(body)
                                                                      phi_protect(storage_json_dump(request_payload(body)),
                                                                                  contains_phi?(body))
                                                                    end,
                                           classification_level:    classification_level(body),
                                           cost_center:             billing(body)[:cost_center],
                                           budget_key:              billing(body)[:budget_id] || billing(body)[:budget_key],
                                           injected_tool_count:     Array(body.dig(:audit, :injected_tools) || body[:injected_tools]).size,
                                           context_tokens:          resolve_context_tokens(body),
                                           request_content_hash:    resolve_request_content_hash(body),
                                           curation_strategy:       body[:curation_strategy] || body.dig(:audit, :curation_strategy),
                                           tool_policy:             body[:tool_policy] || body.dig(:audit, :tool_policy),
                                           requested_at:            recorded_at(body),
                                           inserted_at:             Time.now.utc
                                         }, operation: 'official_record_writer.inference_request')
              llm_request_model[id]
            rescue Sequel::UniqueConstraintViolation => e
              log.debug("[ledger] request collision resolved request_ref=#{request_id} error=#{e.class}")
              existing = llm_request_model.lookup(request_id)
              return enrich_request!(db, existing, body, latest_message) if existing

              raise
            end

            def find_or_create_response_message(db, conversation, request, body)
              uuid = stable_uuid(reference(body, :response_message_id) || "response-message:#{request_ref(body)}")
              existing = llm_message_model.first(uuid: uuid)
              return existing if existing

              latest = llm_message_model[request[:latest_message_id]]
              seq = (latest&.[](:seq) || 1) + 1
              begin
                id = insert_with_savepoint(db, :llm_messages, {
                                             uuid:                         uuid,
                                             conversation_id:              conversation[:id],
                                             parent_message_id:            latest&.[](:id),
                                             message_inference_request_id: request[:id],
                                             seq:                          seq,
                                             role:                         'assistant',
                                             content_type:                 'text',
                                             content:                      response_content(body),
                                             input_tokens:                 0,
                                             output_tokens:                tokens(body)[:output_tokens],
                                             identity_principal_id:        caller_identity_refs(db, body)[:principal_id],
                                             identity_id:                  caller_identity_refs(db, body)[:identity_id],
                                             identity_canonical_name:      identity_canonical_name(body),
                                             created_at:                   recorded_at(body),
                                             inserted_at:                  Time.now.utc
                                           }, operation: 'official_record_writer.response_message')
                llm_message_model[id]
              rescue Sequel::UniqueConstraintViolation => e
                log.debug("[ledger] seq collision resolved uuid=#{uuid} conversation_id=#{conversation[:id]} error=#{e.class}")
                llm_message_model.first(uuid: uuid) ||
                  llm_message_model.first(conversation_id: conversation[:id], seq: seq)
              end
            end

            def find_or_create_response(db, request, response_message, body)
              response_uuid = stable_uuid(reference(body, :provider_response_ref) || "response:#{request_ref(body)}:#{body[:provider] || 'unknown'}")
              existing = llm_response_model.first(uuid: response_uuid)

              # Fallback: if we couldn't find a response by UUID, check if a response
              # already exists for this request (e.g., metering arrived first and created
              # a response with a different UUID). Enrich it instead of creating a duplicate.
              unless existing
                existing = llm_response_model.first(message_inference_request_id: request[:id])
                log.debug("[ledger] response fallback: found existing response id=#{existing[:id]} for request_id=#{request[:id]}") if existing
              end

              if existing
                enrich_response!(db, existing, response_message, body)
                return existing
              end

              vis_resp = visible_response(body)
              think_resp = thinking_response(body)
              phi = contains_phi?(body)

              id = insert_with_savepoint(db, :llm_message_inference_responses, {
                                           uuid:                         response_uuid,
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
                                           response_json:                vis_resp ? phi_protect(storage_json_dump(vis_resp), phi) : nil,
                                           response_thinking_json:       think_resp ? phi_protect(storage_json_dump(think_resp), phi) : nil,
                                           dispatch_path:                body[:dispatch_path] || body[:tier],
                                           error_category:               body[:error_category] || body.dig(:error, :category),
                                           error_code:                   body[:error_code] || body.dig(:error, :code),
                                           error_message:                body[:error_message] || body.dig(:error, :message),
                                           response_content_hash:        resolve_response_content_hash(body),
                                           route_attempts:               (body[:route_attempts] || body.dig(:audit, :route_attempts)).to_i,
                                           escalation_chain_ref:         body[:escalation_chain_ref],
                                           identity_principal_id:        caller_identity_refs(db, body)[:principal_id],
                                           identity_id:                  caller_identity_refs(db, body)[:identity_id],
                                           identity_canonical_name:      identity_canonical_name(body),
                                           responded_at:                 recorded_at(body),
                                           inserted_at:                  Time.now.utc
                                         }, operation: 'official_record_writer.inference_response')
              llm_response_model[id]
            rescue Sequel::UniqueConstraintViolation => e
              log.debug("[ledger] response collision resolved uuid=#{response_uuid} error=#{e.class}")
              existing = llm_response_model.first(uuid: response_uuid)
              if existing
                enrich_response!(db, existing, response_message, body)
                return existing
              end

              raise
            end

            def enrich_response!(db, existing, response_message, body)
              updates = {}
              update_if_missing(updates, existing, :response_message_id, response_message&.[](:id))
              update_if_missing(updates, existing, :tier, tier(body))
              update_if_missing(updates, existing, :provider_instance, provider_instance(body))
              update_if_missing(updates, existing, :finish_reason, finish_reason(body))
              update_if_missing(updates, existing, :dispatch_path, body[:dispatch_path] || body[:tier])
              update_if_missing(updates, existing, :identity_canonical_name, identity_canonical_name(body))
              update_if_missing(updates, existing, :response_content_hash, resolve_response_content_hash(body))

              vis = visible_response(body)
              if vis
                response_json = storage_json_dump(vis)
                update_if_placeholder(updates, existing, :response_json, response_json)
              elsif existing[:response_json].nil?
                # Nothing to add, but also don't overwrite existing data with nil
              end

              think = thinking_response(body)
              if think
                thinking_json = storage_json_dump(think)
                update_if_placeholder(updates, existing, :response_thinking_json, thinking_json)
              elsif existing[:response_thinking_json].nil?
                # Nothing to add
              end

              return if updates.empty?

              db[:llm_message_inference_responses].where(id: existing[:id]).update(updates)
              log.info("[ledger] enriched response id=#{existing[:id]} fields=#{updates.keys.join(',')}")
            end

            # Core guard: never upsert a value that is nil, empty string, or empty JSON object.
            # This prevents a leaner message (e.g., metering) from overwriting valid data
            # written by a richer message (e.g., prompt audit).
            def upsert_guard?(value)
              return false if value.nil?
              return false if value.is_a?(String) && value.strip.empty?
              return false if value.to_s == '{}'

              true
            end

            def update_if_missing(updates, existing, key, value)
              updates[key] = value if existing[key].nil? && upsert_guard?(value)
            end

            def update_if_placeholder(updates, existing, key, value)
              return unless upsert_guard?(value)

              existing_val = existing[key]
              is_placeholder = ['{}', 'null'].include?(existing_val.to_s)
              updates[key] = value if is_placeholder
            end

            CONTEXT_ACCOUNTING_STATUS_RANK = {
              'missing'             => 0,
              'profile_skipped'     => 1,
              'partial'             => 2,
              'estimated'           => 3,
              'provider_reconciled' => 4
            }.freeze

            def find_or_create_metric(db, request, response, body)
              metric_uuid = stable_uuid(reference(body, :metric_id, :metric_ref) || "metric:#{request_ref(body)}")
              existing = llm_metric_model.first(uuid: metric_uuid)
              if existing
                enrich_metric_context_accounting!(db, existing, body)
                return existing
              end

              token_values = tokens(body)
              attrs = {
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
                identity_principal_id:         caller_identity_refs(db, body)[:principal_id],
                identity_id:                   caller_identity_refs(db, body)[:identity_id],
                identity_canonical_name:       identity_canonical_name(body),
                recorded_at:                   recorded_at(body),
                inserted_at:                   Time.now.utc
              }.merge(context_accounting_metric_columns(body))

              id = insert_with_savepoint(db, :llm_message_inference_metrics, attrs,
                                         operation: 'official_record_writer.inference_metric')
              metric = llm_metric_model[id]
              write_context_accounting_events(db, request, response, metric, body)
              metric
            rescue Sequel::UniqueConstraintViolation => e
              log.debug("[ledger] metric collision resolved uuid=#{metric_uuid} error=#{e.class}")
              existing = llm_metric_model.first(uuid: metric_uuid)
              if existing
                enrich_metric_context_accounting!(db, existing, body)
                return existing
              end

              raise
            end

            def context_accounting_metric_columns(body)
              accounting = context_accounting(body)
              token_accounting = context_accounting_tokens(body)
              count_accounting = context_accounting_counts(body)
              {
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
                context_accounting_status:             (accounting[:status] || 'missing').to_s,
                context_accounting_json:               accounting.empty? ? nil : storage_json_dump(accounting)
              }
            end

            def context_accounting(body)
              raw = body[:context_accounting] || body.dig(:audit, :context_accounting)
              raw.is_a?(Hash) ? raw : {}
            end

            def context_accounting_tokens(body)
              context_accounting(body)[:tokens] || {}
            end

            def context_accounting_counts(body)
              context_accounting(body)[:counts] || {}
            end

            def enrich_metric_context_accounting!(db, existing, body)
              incoming = context_accounting(body)
              return if incoming.empty?

              incoming_status = (incoming[:status] || 'missing').to_s
              existing_status = (existing[:context_accounting_status] || 'missing').to_s

              return unless richer_context_accounting?(existing_status, incoming_status)

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
              db[:llm_message_inference_metrics].where(id: existing[:id]).update(updates)
              log.info("[ledger] enriched metric context_accounting id=#{existing[:id]} status=#{incoming_status}")
            rescue StandardError => e
              handle_exception(e, level: :warn, handled: true, operation: 'official_record_writer.enrich_metric_context_accounting')
            end

            def richer_context_accounting?(existing_status, incoming_status)
              CONTEXT_ACCOUNTING_STATUS_RANK.fetch(incoming_status, 0) >=
                CONTEXT_ACCOUNTING_STATUS_RANK.fetch(existing_status, 0)
            end

            def write_context_accounting_events(db, request, response, metric, body)
              accounting = context_accounting(body)
              return unless accounting.is_a?(Hash)

              events = Array(accounting[:events])
              return if events.empty?

              req_ref = request[:request_ref]
              events.each_with_index do |event, index|
                normalized = event.transform_keys { |key| key.respond_to?(:to_sym) ? key.to_sym : key }
                uuid = stable_uuid("context-accounting:#{req_ref}:#{index}:#{normalized[:event_type]}:#{normalized[:component]}")
                next if db[:llm_context_accounting_events].where(uuid: uuid).first

                insert_with_savepoint(db, :llm_context_accounting_events, {
                                        uuid:                          uuid,
                                        message_inference_request_id:  request[:id],
                                        message_inference_response_id: response&.[](:id),
                                        message_inference_metric_id:   metric&.[](:id),
                                        conversation_ref:              body[:conversation_id].to_s,
                                        request_ref:                   req_ref,
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
                                      }, operation: 'official_record_writer.context_accounting_event')
              end
            rescue StandardError => e
              handle_exception(e, level: :warn, handled: true, operation: 'official_record_writer.write_context_accounting_events')
            end

            def insert_row(db, table, attributes, operation:)
              Helpers::PersistenceLogging.insert_row(db, table, attributes, operation: operation, warn_on_unique: false)
            end

            def insert_with_savepoint(db, table, attributes, operation:)
              db.transaction(savepoint: true) do
                insert_row(db, table, attributes, operation: operation)
              end
            end

            def request_ref(body)
              body[:__ledger_request_ref] ||= explicit_request_ref(body) ||
                                              correlation_id(body) ||
                                              generated_request_ref(body)
            end

            def link_response_message!(db, response_message, response)
              return unless response_message && response
              return if response_message[:message_inference_response_id] == response[:id]

              db[:llm_messages].where(id: response_message[:id]).update(message_inference_response_id: response[:id])
            end

            def enrich_request!(db, existing, body, latest_message = nil)
              updates = {}
              update_if_missing(updates, existing, :latest_message_id, latest_message&.[](:id))
              caller_refs = caller_identity_refs(db, body)
              update_if_missing(updates, existing, :caller_identity_id, caller_refs[:identity_id])
              update_if_missing(updates, existing, :caller_principal_id, caller_refs[:principal_id])
              update_if_missing(updates, existing, :runtime_caller_type, caller_type(body))
              update_if_missing(updates, existing, :runtime_caller_class, runtime_caller_class(body))
              update_if_missing(updates, existing, :runtime_caller_client, runtime_caller_client(body))
              update_if_missing(updates, existing, :identity_canonical_name, identity_canonical_name(body))
              update_if_missing(updates, existing, :request_content_hash, resolve_request_content_hash(body))

              request_json = request_payload(body) ? storage_json_dump(request_payload(body)) : nil
              if request_json
                update_if_placeholder(updates, existing, :request_json, request_json)
              elsif existing[:request_json].nil?
                # Nothing to add
              end

              msg_count = Array(body.dig(:request, :messages) || body[:messages]).size
              updates[:context_message_count] = msg_count if existing[:context_message_count].to_i.zero? && msg_count.positive?

              return existing if updates.empty?

              db[:llm_message_inference_requests].where(id: existing[:id]).update(updates)
              log.info("[ledger] enriched request id=#{existing[:id]} fields=#{updates.keys.join(',')}")
              existing.refresh
            end

            def caller_identity(body)
              caller_identity_refs(::Legion::Data.connection, body)[:identity_id]
            end

            def caller_principal(body)
              caller_identity_refs(::Legion::Data.connection, body)[:principal_id]
            end

            def caller_type(body)
              raw_type = body[:caller_type] ||
                         body.dig(:identity, :type) ||
                         body.dig(:caller, :requested_by, :type) ||
                         body.dig(:caller, :source)
              return normalize_caller_type(raw_type) if present?(raw_type)

              parsed_identity_descriptor(body)[:kind]
            end

            def runtime_caller_class(body)
              body.dig(:caller, :class) || body.dig(:caller, :caller_class) ||
                body.dig(:caller, :source_class) || body[:runtime_caller_class]
            end

            def runtime_caller_client(body)
              body.dig(:caller, :client) || body.dig(:caller, :user_agent) ||
                body[:runtime_caller_client]
            end

            def caller_identity_refs(db, body)
              body[:__ledger_caller_identity_refs] ||= begin
                explicit_identity_id = integer_or_nil(body[:caller_identity_id] || body.dig(:caller, :requested_by, :id))
                explicit_principal_id = integer_or_nil(body[:caller_principal_id] ||
                                                       body.dig(:caller, :requested_by, :principal_id))

                explicit_identity_id ||= integer_or_nil(body[:__header_identity_id])
                explicit_principal_id ||= integer_or_nil(body[:__header_principal_id])

                refs = { principal_id: explicit_principal_id, identity_id: explicit_identity_id }.compact
                unless refs[:principal_id] && refs[:identity_id]
                  if explicit_identity_id && !explicit_principal_id && identity_tables_available?(db)
                    row = db[:identities].where(id: explicit_identity_id).first
                    refs[:principal_id] = row[:principal_id] if row
                  end

                  resolved = resolve_identity(db, body)
                  refs[:principal_id] ||= resolved[:principal_id]
                  refs[:identity_id] ||= resolved[:identity_id]
                end
                refs.compact
              end
            end

            def resolve_identity(db, body)
              return {} unless identity_tables_available?(db)

              descriptor = parsed_identity_descriptor(body)
              return {} unless present?(descriptor[:canonical_name])

              provider = find_or_create_identity_provider(db, descriptor[:provider_name])
              principal = find_or_create_identity_principal(db, descriptor)
              identity = find_or_create_identity(db, principal, provider, descriptor)

              { principal_id: principal[:id], identity_id: identity[:id] }
            rescue StandardError => e
              handle_exception(e, level: :warn, handled: true, operation: 'official_record_writer.identity_resolution')
              {}
            end

            def parsed_identity_descriptor(body)
              raw_identity = body[:caller_identity] ||
                             body.dig(:identity, :identity) ||
                             body.dig(:identity, :canonical_name) ||
                             body.dig(:caller, :requested_by, :identity) ||
                             body.dig(:caller, :requested_by, :canonical_name) ||
                             body.dig(:caller, :requested_by, :id)
              return {} unless present?(raw_identity)

              raw_type = body[:caller_type] ||
                         body.dig(:identity, :type) ||
                         body.dig(:caller, :requested_by, :type) ||
                         body.dig(:caller, :source)
              provider_name = body.dig(:identity, :credential) ||
                              body.dig(:caller, :requested_by, :credential) ||
                              'local'
              parse_identity_descriptor(raw_identity, raw_type, provider_name)
            end

            def parse_identity_descriptor(raw_identity, raw_type, provider_name)
              text = raw_identity.to_s
              kind = normalize_caller_type(raw_type)
              canonical = text

              if text.include?(':') && !text.include?('@')
                prefix, remainder = text.split(':', 2)
                prefix_kind = normalize_caller_type(prefix)
                if prefix_kind && present?(remainder)
                  kind ||= prefix_kind
                  canonical = remainder
                end
              end

              {
                canonical_name:        canonical,
                kind:                  kind || 'unknown',
                provider_identity_key: text,
                provider_name:         normalize_provider_name(provider_name)
              }
            end

            def find_or_create_identity_provider(db, provider_name)
              table = db[:identity_providers]
              existing = table.where(name: provider_name).first
              return existing if existing

              id = insert_with_savepoint(db, :identity_providers, {
                                           uuid:          deterministic_uuid("identity_provider:#{provider_name}"),
                                           name:          provider_name,
                                           provider_type: provider_name == 'local' ? 'local' : 'external',
                                           facing:        'internal',
                                           source:        'ledger',
                                           created_at:    Time.now.utc,
                                           updated_at:    Time.now.utc
                                         }, operation: 'official_record_writer.identity_provider')
              table[id: id]
            rescue Sequel::UniqueConstraintViolation => e
              handle_exception(e, level: :debug, handled: true, operation: 'official_record_writer.identity_provider_race')
              existing = table.where(name: provider_name).first
              return existing if existing

              raise
            end

            def find_or_create_identity_principal(db, descriptor)
              table = db[:identity_principals]
              existing = table.where(canonical_name: descriptor[:canonical_name], kind: descriptor[:kind]).first
              return existing if existing

              id = insert_with_savepoint(db, :identity_principals, {
                                           uuid:           deterministic_uuid("identity_principal:#{descriptor[:kind]}:#{descriptor[:canonical_name]}"),
                                           canonical_name: descriptor[:canonical_name],
                                           kind:           descriptor[:kind],
                                           display_name:   descriptor[:canonical_name],
                                           last_seen_at:   Time.now.utc,
                                           created_at:     Time.now.utc,
                                           updated_at:     Time.now.utc
                                         }, operation: 'official_record_writer.identity_principal')
              table[id: id]
            rescue Sequel::UniqueConstraintViolation => e
              handle_exception(e, level: :debug, handled: true, operation: 'official_record_writer.identity_principal_race')
              existing = table.where(canonical_name: descriptor[:canonical_name], kind: descriptor[:kind]).first
              return existing if existing

              raise
            end

            def find_or_create_identity(db, principal, provider, descriptor)
              table = db[:identities]
              existing = table.where(
                principal_id:          principal[:id],
                provider_id:           provider[:id],
                provider_identity_key: descriptor[:provider_identity_key]
              ).first
              return existing if existing

              uuid_key = "identity:#{principal[:id]}:#{provider[:id]}:#{descriptor[:provider_identity_key]}"
              id = insert_with_savepoint(db, :identities, {
                                           uuid:                  deterministic_uuid(uuid_key),
                                           principal_id:          principal[:id],
                                           provider_id:           provider[:id],
                                           provider_identity_key: descriptor[:provider_identity_key],
                                           last_authenticated_at: Time.now.utc,
                                           account_type:          'primary',
                                           is_default:            true,
                                           created_at:            Time.now.utc,
                                           updated_at:            Time.now.utc
                                         }, operation: 'official_record_writer.identity')
              table[id: id]
            rescue Sequel::UniqueConstraintViolation => e
              handle_exception(e, level: :debug, handled: true, operation: 'official_record_writer.identity_race')
              existing = table.where(principal_id: principal[:id], provider_id: provider[:id],
                                     provider_identity_key: descriptor[:provider_identity_key]).first
              return existing if existing

              raise
            end

            def identity_tables_available?(db)
              db.table_exists?(:identity_providers) &&
                db.table_exists?(:identity_principals) &&
                db.table_exists?(:identities)
            end

            def normalize_caller_type(value)
              return nil unless present?(value)

              normalized = value.to_s.downcase.gsub(/[^a-z0-9_:-]+/, '_').split(':', 2).first
              return 'human' if normalized == 'user'

              normalized
            end

            def normalize_provider_name(value)
              raw = present?(value) ? value.to_s : 'local'
              raw.downcase.gsub(/[^a-z0-9_.:-]+/, '-').gsub(/\A-+|-+\z/, '')
            end

            def integer_or_nil(value)
              return nil if value.nil?
              return value if value.is_a?(Integer)

              int = value.to_s.to_i
              int.positive? ? int : nil
            end

            def resolve_parent_request_id(_db, body)
              parent_ref = body[:parent_request_id] || body.dig(:context, :parent_request_id) || body.dig(:caller, :parent_request_ref)
              return nil unless present?(parent_ref)

              if parent_ref.is_a?(Integer)
                parent_ref
              else
                parent = llm_request_model.lookup(parent_ref.to_s)
                parent&.[](:id)
              end
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
              body[:request] || body[:messages]
            end

            def request_content(body)
              messages = body.dig(:request, :messages) || body[:messages]
              message = Array(messages).reverse.find { |item| item[:role].to_s == 'user' } || Array(messages).last
              content = message&.dig(:content) || body[:prompt] || body[:text]
              stringify_content(content)
            end

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

            def extract_inline_thinking(text)
              if defined?(::Legion::Extensions::Llm::Responses::ThinkingExtractor)
                extraction = ::Legion::Extensions::Llm::Responses::ThinkingExtractor.extract(text)
                [extraction.content, extraction.thinking]
              else
                [text, nil]
              end
            end

            def response_content(body)
              vis = visible_response(body)
              return nil unless vis

              stringify_content(vis[:content] || vis.dig(:message, :content))
            end

            def finish_reason(body)
              return body[:finish_reason] if body[:finish_reason]
              return nil unless body[:response].is_a?(Hash)

              body.dig(:response, :finish_reason) || body.dig(:response, :stop, :reason)
            end

            ALLOWED_CLASSIFICATION_LEVELS = %w[public internal confidential restricted].freeze

            def classification_level(body)
              raw = body[:classification_level] || body.dig(:classification, :level)
              return 'internal' if raw.nil? || raw.to_s.empty?

              normalized = raw.to_s.downcase
              ALLOWED_CLASSIFICATION_LEVELS.include?(normalized) ? normalized : 'internal'
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

            def deterministic_uuid(value)
              hex = Digest::SHA256.hexdigest(value.to_s)[0, 32]
              "#{hex[0, 8]}-#{hex[8, 4]}-#{hex[12, 4]}-#{hex[16, 4]}-#{hex[20, 12]}"
            end

            def next_message_seq(db, conversation)
              db[:llm_messages].where(conversation_id: conversation[:id]).max(:seq).to_i + 1
            end

            def explicit_request_ref(body)
              reference(body, :request_id, :request_ref)
            end

            def generated_request_ref(body)
              body[:__ledger_generated_request_ref] ||= SecureRandom.uuid
            end

            def llm_conversation_model
              ensure_llm_models_loaded!
              ::Legion::Data::Models::LLM::Conversation
            end

            def llm_message_model
              ensure_llm_models_loaded!
              ::Legion::Data::Models::LLM::Message
            end

            def llm_request_model
              ensure_llm_models_loaded!
              ::Legion::Data::Models::LLM::MessageInferenceRequest
            end

            def llm_response_model
              ensure_llm_models_loaded!
              ::Legion::Data::Models::LLM::MessageInferenceResponse
            end

            def llm_metric_model
              ensure_llm_models_loaded!
              ::Legion::Data::Models::LLM::MessageInferenceMetric
            end

            def ensure_llm_models_loaded!
              require 'legion/data/model' unless defined?(::Legion::Data::Models)
              ::Legion::Data::Models.instance_variable_set(:@loaded_models, []) unless ::Legion::Data::Models.loaded_models

              missing = []
              missing << 'llm/conversation' unless defined?(::Legion::Data::Models::LLM::Conversation)
              missing << 'llm/message' unless defined?(::Legion::Data::Models::LLM::Message)
              missing << 'llm/message_inference_request' unless defined?(::Legion::Data::Models::LLM::MessageInferenceRequest)
              missing << 'llm/message_inference_response' unless defined?(::Legion::Data::Models::LLM::MessageInferenceResponse)
              missing << 'llm/message_inference_metric' unless defined?(::Legion::Data::Models::LLM::MessageInferenceMetric)

              ::Legion::Data::Models.require_sequel_models(missing) unless missing.empty?
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

            def phi_protect(json_string, is_phi)
              return json_string unless is_phi && crypt_available?

              Legion::Crypt.encrypt(json_string)
            rescue StandardError => e
              handle_exception(e, level: :warn, handled: true, operation: 'official_record_writer.phi_encrypt')
              json_string
            end

            def crypt_available?
              defined?(Legion::Crypt) && Legion::Crypt.respond_to?(:encrypt)
            end

            def json_dump(value)
              Helpers::Json.dump(value)
            end

            def storage_json_dump(value)
              Helpers::Json.dump(value, pretty: true)
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

            def identity_canonical_name(body)
              parsed_identity_descriptor(body)[:canonical_name]
            end

            def present?(value)
              !value.nil? && !(value.respond_to?(:empty?) && value.empty?)
            end

            def compute_content_hash(content)
              return nil if content.nil? || content.to_s.empty?

              Digest::SHA256.hexdigest(json_dump(content))[0..31]
            end

            # Prefer precomputed hash from emitter (A4: hash ships instead of raw content).
            # Falls back to computing from raw content for backward compatibility.
            def resolve_request_content_hash(body)
              return body[:request_content_hash] if present?(body[:request_content_hash])

              compute_content_hash(body.dig(:request, :content) || body.dig(:audit, :request_content))
            end

            # Prefer precomputed hash from emitter (A4: hash ships instead of raw content).
            # Falls back to computing from raw content for backward compatibility.
            def resolve_response_content_hash(body)
              return body[:response_content_hash] if present?(body[:response_content_hash])

              compute_content_hash(body[:response_content] || body.dig(:audit, :response_content))
            end

            def resolve_context_tokens(body)
              raw = body[:tokens] || body[:audit] || body
              val = raw[:input_tokens] || raw[:input] || raw[:context_tokens] || raw[:prompt_tokens]
              present?(val) ? val.to_i : 0
            end
          end
        end
      end
    end
  end
end
