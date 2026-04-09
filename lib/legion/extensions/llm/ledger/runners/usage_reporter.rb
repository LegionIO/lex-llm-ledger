# frozen_string_literal: true

module Legion
  module Extensions
    module Llm
      module Ledger
        module Runners
          module UsageReporter
            extend self

            def summary(since: nil, until_: nil, period: nil, group_by: nil)
              dataset = ::Legion::Data::DB[:metering_records]
              dataset = apply_time_window(dataset, since, until_, period)
              dataset = dataset.group_and_count(group_by.to_sym) if group_by
              dataset.select_append(
                Sequel.function(:SUM, :input_tokens).as(:total_input_tokens),
                Sequel.function(:SUM, :output_tokens).as(:total_output_tokens),
                Sequel.function(:SUM, :total_tokens).as(:grand_total_tokens),
                Sequel.function(:SUM, :cost_usd).as(:total_cost_usd),
                Sequel.function(:AVG, :latency_ms).as(:avg_latency_ms),
                Sequel.function(:COUNT, Sequel.lit('*')).as(:request_count)
              ).all
            end

            def worker_usage(worker_id:, since: nil, until_: nil, period: nil)
              dataset = ::Legion::Data::DB[:metering_records].where(worker_id: worker_id)
              dataset = apply_time_window(dataset, since, until_, period)
              dataset.select(
                :provider, :model_id, :request_type,
                Sequel.function(:SUM, :total_tokens).as(:total_tokens),
                Sequel.function(:SUM, :cost_usd).as(:cost_usd),
                Sequel.function(:COUNT, Sequel.lit('*')).as(:count)
              ).group(:provider, :model_id, :request_type).all
            end

            def budget_check(budget_id:, budget_usd:, threshold: 0.8, period: 'month')
              dataset = ::Legion::Data::DB[:metering_records].where(budget_id: budget_id)
              dataset = apply_time_window(dataset, nil, nil, period)
              spent = dataset.sum(:cost_usd).to_f

              {
                budget_id:         budget_id,
                budget_usd:        budget_usd.to_f,
                spent_usd:         spent,
                remaining_usd:     [budget_usd.to_f - spent, 0.0].max,
                exceeded:          spent > budget_usd.to_f,
                threshold_reached: spent >= (budget_usd.to_f * threshold.to_f)
              }
            end

            def top_consumers(limit: 10, group_by: 'node_id', since: nil, until_: nil, period: 'day')
              col = group_by.to_sym
              dataset = ::Legion::Data::DB[:metering_records]
              dataset = apply_time_window(dataset, since, until_, period)
              dataset.select(
                col,
                Sequel.function(:SUM, :total_tokens).as(:total_tokens),
                Sequel.function(:SUM, :cost_usd).as(:cost_usd),
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
              dataset = dataset.where { inserted_at >= since }  if since
              dataset = dataset.where { inserted_at <= until_ } if until_
              dataset
            end
          end
        end
      end
    end
  end
end
