# frozen_string_literal: true

module Legion
  module Extensions
    module Llm
      module Ledger
        module Runners
          module ProviderStats
            extend self

            PERIOD_SECONDS = { 'hour' => 3600, 'day' => 86_400, 'week' => 604_800, 'month' => 2_592_000 }.freeze

            def health_report
              ds = official_metrics
                   .where { Sequel[:llm_message_inference_metrics][:recorded_at] >= Time.now.utc - 86_400 }
                   .select_group(
                     Sequel[:llm_message_inference_metrics][:provider],
                     Sequel[:llm_message_inference_responses][:provider_instance],
                     Sequel[:llm_message_inference_metrics][:model_key].as(:model_id),
                     Sequel[:llm_message_inference_requests][:operation]
                   )
                   .select_append(
                     Sequel.function(:COUNT, Sequel.lit('*')).as(:request_count),
                     Sequel.function(:SUM, Sequel[:llm_message_inference_metrics][:total_tokens]).as(:total_tokens),
                     Sequel.function(:AVG, Sequel[:llm_message_inference_metrics][:latency_ms]).as(:avg_latency_ms),
                     Sequel.function(:MAX, Sequel[:llm_message_inference_metrics][:latency_ms]).as(:max_latency_ms)
                   )
                   .all

              ds.map do |row|
                attrs = row.respond_to?(:to_h) ? row.to_h : row.values
                attrs.merge(status: latency_status(row[:avg_latency_ms]))
              end
            end

            def circuit_summary(period: 'hour')
              since = period_start(period)
              official_metrics
                .where { Sequel[:llm_message_inference_metrics][:inserted_at] >= since }
                .select_group(
                  Sequel[:llm_message_inference_metrics][:provider],
                  Sequel[:llm_message_inference_responses][:provider_instance],
                  Sequel[:llm_message_inference_metrics][:model_key].as(:model_id),
                  Sequel[:llm_message_inference_requests][:operation],
                  Sequel[:llm_message_inference_metrics][:tier]
                )
                .select_append(
                  Sequel.function(:COUNT, Sequel.lit('*')).as(:request_count),
                  Sequel.function(:AVG, Sequel[:llm_message_inference_metrics][:latency_ms]).as(:avg_latency_ms),
                  Sequel.function(:SUM, Sequel[:llm_message_inference_metrics][:cost_usd]).as(:cost_usd)
                )
                .order(Sequel.desc(:request_count))
                .all
            end

            def provider_detail(provider:, period: 'day')
              since = period_start(period)
              official_metrics
                .where(Sequel[:llm_message_inference_metrics][:provider] => provider)
                .where { Sequel[:llm_message_inference_metrics][:inserted_at] >= since }
                .select_group(
                  Sequel[:llm_message_inference_metrics][:provider],
                  Sequel[:llm_message_inference_responses][:provider_instance],
                  Sequel[:llm_message_inference_metrics][:model_key].as(:model_id),
                  Sequel[:llm_message_inference_requests][:operation]
                )
                .select_append(
                  Sequel.function(:COUNT, Sequel.lit('*')).as(:count),
                  Sequel.function(:SUM, Sequel[:llm_message_inference_metrics][:total_tokens]).as(:total_tokens),
                  Sequel.function(:AVG, Sequel[:llm_message_inference_metrics][:latency_ms]).as(:avg_latency_ms),
                  Sequel.function(:SUM, Sequel[:llm_message_inference_metrics][:cost_usd]).as(:cost_usd)
                )
                .order(Sequel.desc(:count))
                .all
            end

            private

            def official_metrics
              metric = Sequel[:llm_message_inference_metrics]
              Legion::Data::Models::LLM::MessageInferenceMetric.dataset
                                                               .naked
                                                               .join(:llm_message_inference_requests, id: metric[:message_inference_request_id])
                                                               .join(:llm_message_inference_responses, id: metric[:message_inference_response_id])
            end

            def period_start(period)
              Time.now.utc - PERIOD_SECONDS.fetch(period.to_s, 86_400)
            end

            def latency_status(avg_ms)
              if avg_ms.nil? then :unknown
              elsif avg_ms < 2_000 then :healthy
              elsif avg_ms < 8_000 then :degraded
              else :critical
              end
            end
          end
        end
      end
    end
  end
end
