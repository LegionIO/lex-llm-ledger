# frozen_string_literal: true

require 'legion/logging'

module Legion
  module Extensions
    module Llm
      module Ledger
        module Runners
          module Reconciliation
            extend self
            extend Legion::Logging::Helper

            BATCH_SIZE = 200
            LOOKBACK_SECONDS = 300

            def link_orphaned_tool_calls
              linked = 0

              orphans = Legion::Data::Models::LLM::ToolCall
                        .where(message_inference_response_id: nil)
                        .where { inserted_at >= Time.now.utc - LOOKBACK_SECONDS }
                        .limit(BATCH_SIZE)
                        .all

              orphans.each do |tool_call|
                response = find_response_for_tool_call(tool_call)
                next unless response

                next_index = response.tool_calls_dataset.max(:tool_call_index).to_i + 1

                tool_call.update(
                  message_inference_response_id: response[:id],
                  tool_call_index:               next_index
                )
                linked += 1
              end

              log.info("[ledger] reconciliation: linked #{linked} orphaned tool calls") if linked.positive?
              { result: :ok, linked: linked }
            rescue StandardError => e
              handle_exception(e, level: :error, handled: true, operation: 'reconciliation.tool_calls')
              { result: :error, error: e.message }
            end

            def link_metering_messages
              linked = 0

              requests_without_messages = Legion::Data::Models::LLM::MessageInferenceRequest
                                          .where(latest_message_id: nil)
                                          .where { inserted_at >= Time.now.utc - LOOKBACK_SECONDS }
                                          .limit(BATCH_SIZE)
                                          .all

              requests_without_messages.each do |request|
                next unless request[:conversation_id]

                conversation = request.conversation
                next unless conversation

                message = conversation.messages_dataset.order(Sequel.desc(:seq)).first
                next unless message

                request.update(latest_message_id: message[:id])
                linked += 1
              end

              log.info("[ledger] reconciliation: linked #{linked} metering requests to messages") if linked.positive?
              { result: :ok, linked: linked }
            rescue StandardError => e
              handle_exception(e, level: :error, handled: true, operation: 'reconciliation.metering_messages')
              { result: :error, error: e.message }
            end

            private

            def find_response_for_tool_call(tool_call)
              return nil unless tool_call[:conversation_id] # rubocop:disable Legion/Extension/RunnerReturnHash

              request = Legion::Data::Models::LLM::MessageInferenceRequest
                        .where(conversation_id: tool_call[:conversation_id])
                        .order(Sequel.desc(:inserted_at))
                        .first
              return nil unless request # rubocop:disable Legion/Extension/RunnerReturnHash

              request.message_inference_responses_dataset.first
            end
          end
        end
      end
    end
  end
end
