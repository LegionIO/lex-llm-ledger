# frozen_string_literal: true

module Legion
  module Extensions
    module Llm
      module Ledger
        module Runners
          module UsageReporter
            extend self

            def summary(since: nil, until_: nil, period: nil, group_by: nil)
              dataset = official_metrics
              dataset = apply_time_window(dataset, since, until_, period)
              if group_by
                column = group_column(group_by)
                dataset = dataset.select_group(column.as(group_by.to_sym))
              end
              dataset.select_append(
                Sequel.function(:SUM, metric[:input_tokens]).as(:total_input_tokens),
                Sequel.function(:SUM, metric[:output_tokens]).as(:total_output_tokens),
                Sequel.function(:SUM, metric[:total_tokens]).as(:grand_total_tokens),
                Sequel.function(:SUM, metric[:cost_usd]).as(:total_cost_usd),
                Sequel.function(:AVG, metric[:latency_ms]).as(:avg_latency_ms),
                Sequel.function(:COUNT, Sequel.lit('*')).as(:request_count)
              ).all
            end

            def worker_usage(worker_id:, since: nil, until_: nil, period: nil)
              dataset = official_metrics.where(response[:provider_instance] => worker_id)
              dataset = apply_time_window(dataset, since, until_, period)
              dataset.select(
                metric[:provider],
                response[:provider_instance],
                metric[:model_key].as(:model_id),
                request[:operation],
                Sequel.function(:SUM, metric[:total_tokens]).as(:total_tokens),
                Sequel.function(:SUM, metric[:cost_usd]).as(:cost_usd),
                Sequel.function(:COUNT, Sequel.lit('*')).as(:count)
              ).group(metric[:provider], response[:provider_instance], metric[:model_key], request[:operation]).all
            end

            def budget_check(budget_id:, budget_usd:, threshold: 0.8, period: 'month')
              dataset = official_metrics.where(metric[:budget_key] => budget_id)
              dataset = apply_time_window(dataset, nil, nil, period)
              spent = dataset.sum(metric[:cost_usd]).to_f

              {
                budget_id:         budget_id,
                budget_usd:        budget_usd.to_f,
                spent_usd:         spent,
                remaining_usd:     [budget_usd.to_f - spent, 0.0].max,
                exceeded:          spent > budget_usd.to_f,
                threshold_reached: spent >= (budget_usd.to_f * threshold.to_f)
              }
            end

            def top_consumers(limit: 10, group_by: 'provider_instance', since: nil, until_: nil, period: 'day')
              col = group_column(group_by)
              dataset = official_metrics
              dataset = apply_time_window(dataset, since, until_, period)
              dataset.select(
                col.as(group_by.to_sym),
                Sequel.function(:SUM, metric[:total_tokens]).as(:total_tokens),
                Sequel.function(:SUM, metric[:cost_usd]).as(:cost_usd),
                Sequel.function(:COUNT, Sequel.lit('*')).as(:request_count)
              ).group(col)
                     .order(Sequel.desc(:cost_usd))
                     .limit(limit)
                     .all
            end

            private

            def apply_time_window(dataset, since, until_, period)
              if period
                since  = Helpers::Queries.period_start(period)
                until_ = Time.now.utc
              end
              dataset = dataset.where { Sequel[:llm_message_inference_metrics][:inserted_at] >= since }  if since
              dataset = dataset.where { Sequel[:llm_message_inference_metrics][:inserted_at] <= until_ } if until_
              dataset
            end

            def official_metrics
              ::Legion::Data.connection[:llm_message_inference_metrics]
                            .join(:llm_message_inference_requests, id: metric[:message_inference_request_id])
                            .join(:llm_message_inference_responses, id: metric[:message_inference_response_id])
            end

            def group_column(name)
              {
                provider:          metric[:provider],
                provider_instance: response[:provider_instance],
                model_id:          metric[:model_key],
                operation:         request[:operation],
                tier:              metric[:tier],
                cost_center:       metric[:cost_center],
                budget_id:         metric[:budget_key]
              }.fetch(name.to_sym)
            end

            def metric
              Sequel[:llm_message_inference_metrics]
            end

            def request
              Sequel[:llm_message_inference_requests]
            end

            def response
              Sequel[:llm_message_inference_responses]
            end
          end
        end
      end
    end
  end
end
