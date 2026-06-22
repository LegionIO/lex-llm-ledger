# frozen_string_literal: true

require 'digest'
require 'legion/logging'
require_relative 'json'

module Legion
  module Extensions
    module Llm
      module Ledger
        module Helpers
          # Lifecycle enrichment: field extractors, upsert guards, PHI protection,
          # context accounting, and response/request enrichment logic.
          # No DB writes — pure functions and in-memory enrichment only.
          module LifecycleEnrichment
            extend Legion::Logging::Helper

            ALLOWED_CLASSIFICATION_LEVELS = %w[public internal confidential restricted].freeze

            # --- Response Enrichment —

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
              end

              think = thinking_response(body)
              if think
                thinking_json = storage_json_dump(think)
                update_if_placeholder(updates, existing, :response_thinking_json, thinking_json)
              end

              return if updates.empty?

              db[:llm_message_inference_responses].where(id: existing[:id]).update(updates)
              log.info("[ledger] enriched response id=#{existing[:id]} fields=#{updates.keys.join(',')}")
            end

            # --- Request Enrichment —

            def enrich_request!(db, existing, body, latest_message = nil)
              updates = {}
              update_if_missing(updates, existing, :latest_message_id, latest_message&.[](:id))
              update_if_missing(updates, existing, :runtime_caller_class, runtime_caller_class(body))
              update_if_missing(updates, existing, :runtime_caller_client, runtime_caller_client(body))
              update_if_missing(updates, existing, :identity_canonical_name, identity_canonical_name(body))
              update_if_missing(updates, existing, :request_content_hash, resolve_request_content_hash(body))

              request_json = request_payload(body) ? storage_json_dump(request_payload(body)) : nil
              update_if_placeholder(updates, existing, :request_json, request_json)

              return if updates.empty?

              db[:llm_message_inference_requests].where(id: existing[:id]).update(updates)
              log.info("[ledger] enriched request id=#{existing[:id]} fields=#{updates.keys.join(',')}")
            end

            # --- Metric Context Accounting Enrichment —

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
              handle_exception(e, level: :warn, handled: true, operation: 'lifecycle_enrichment.context_accounting')
            end

            def richer_context_accounting?(existing_status, incoming_status)
              CONTEXT_ACCOUNTING_STATUS_RANK.fetch(incoming_status, 0) >=
                CONTEXT_ACCOUNTING_STATUS_RANK.fetch(existing_status, 0)
            end

            CONTEXT_ACCOUNTING_STATUS_RANK = {
              'missing'             => 0,
              'profile_skipped'     => 1,
              'partial'             => 2,
              'estimated'           => 3,
              'provider_reconciled' => 4
            }.freeze

            # --- Upsert Guards —

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

            # --- Field Extractors —

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

            def token_count(body, key)
              integer(body[key])
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

            def caller_type(body)
              raw_type = body[:caller_type] ||
                         body.dig(:identity, :type) ||
                         body.dig(:caller, :requested_by, :type) ||
                         body.dig(:caller, :source)
              return Legion::Extensions::Llm::Ledger::Helpers::IdentityResolution.normalize_caller_type(raw_type) if present?(raw_type)

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

            # --- Identity Canonical Name (delegates to IdentityResolution) —

            def identity_canonical_name(body)
              Legion::Extensions::Llm::Ledger::Helpers::IdentityResolution.identity_canonical_name(body)
            end

            # --- Context Accounting —

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

            # --- Resolve Parent Request —

            def resolve_parent_request_id(db, body)
              parent_ref = body[:parent_request_id] || body.dig(:context, :parent_request_id) || body.dig(:caller, :parent_request_ref)
              return nil unless present?(parent_ref)

              if parent_ref.is_a?(Integer)
                parent_ref
              else
                parent = Legion::Data::Models::LLM::MessageInferenceRequest.lookup(parent_ref.to_s)
                parent&.[](:id)
              end
            end

            # --- Content Hashing —

            def compute_content_hash(content)
              return nil if content.nil? || content.to_s.empty?

              Digest::SHA256.hexdigest(json_dump(content))[0..31]
            end

            def resolve_request_content_hash(body)
              return body[:request_content_hash] if present?(body[:request_content_hash])

              compute_content_hash(body.dig(:request, :content) || body.dig(:audit, :request_content))
            end

            def resolve_response_content_hash(body)
              return body[:response_content_hash] if present?(body[:response_content_hash])

              compute_content_hash(body[:response_content] || body.dig(:audit, :response_content))
            end

            def resolve_context_tokens(body)
              body[:context_tokens] || body.dig(:tokens, :context_tokens)
            end

            # --- String / JSON Utilities —

            def reference(body, *keys)
              keys.lazy.map { |key| body[key] }.find { |value| present?(value) }&.to_s
            end

            def present?(value)
              !value.nil? && !(value.respond_to?(:empty?) && value.empty?)
            end

            def stringify_content(content)
              return nil if content.nil?
              return content if content.is_a?(String)

              json_dump(content)
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

            def integer(value, default: 0)
              return default if value.nil?

              value.to_i
            end

            # --- PHI Protection —

            def phi_protect(json_string, is_phi)
              return json_string unless is_phi && crypt_available?

              Legion::Crypt.encrypt(json_string)
            rescue StandardError => e
              handle_exception(e, level: :warn, handled: true, operation: 'lifecycle_enrichment.phi_encrypt')
              json_string
            end

            def crypt_available?
              defined?(Legion::Crypt) && Legion::Crypt.respond_to?(:encrypt)
            end

            # --- Thinking Extraction —

            def extract_inline_thinking(text)
              if defined?(::Legion::Extensions::Llm::Responses::ThinkingExtractor)
                extraction = ::Legion::Extensions::Llm::Responses::ThinkingExtractor.extract(text)
                [extraction.content, extraction.thinking]
              else
                [text, nil]
              end
            end

            # --- Identity Descriptor (delegates to IdentityResolution) —

            def parsed_identity_descriptor(body)
              Legion::Extensions::Llm::Ledger::Helpers::IdentityResolution.parsed_identity_descriptor(body)
            end

            # --- JSON —

            def json_dump(value)
              Legion::Extensions::Llm::Ledger::Helpers::Json.dump(value)
            end

            def storage_json_dump(value)
              Legion::Extensions::Llm::Ledger::Helpers::Json.dump(value, pretty: true)
            end

            private_class_method :present?
          end
        end
      end
    end
  end
end
