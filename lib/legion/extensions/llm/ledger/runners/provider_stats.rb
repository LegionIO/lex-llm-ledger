# frozen_string_literal: true

module Legion
  module Extensions
    module LLM
      module Ledger
        module Runners
          module ProviderStats
            extend self # rubocop:disable Style/ModuleFunction

            def health_report
              ds = ::Legion::Data::DB[:metering_records]
                   .where { inserted_at >= Time.now.utc - 86_400 }
                   .select(
                     :provider,
                     Sequel.function(:COUNT, Sequel.lit('*')).as(:request_count),
                     Sequel.function(:SUM, :total_tokens).as(:total_tokens),
                     Sequel.function(:AVG, :latency_ms).as(:avg_latency_ms),
                     Sequel.function(:MAX, :latency_ms).as(:max_latency_ms)
                   )
                   .group(:provider)
                   .all

              ds.map { |row| row.merge(status: Helpers::Queries.latency_status(row[:avg_latency_ms])) }
            end

            def circuit_summary(period: 'hour')
              since = Helpers::Queries.period_start(period)
              ::Legion::Data::DB[:metering_records]
                .where { inserted_at >= since }
                .select(
                  :provider, :tier,
                  Sequel.function(:COUNT, Sequel.lit('*')).as(:request_count),
                  Sequel.function(:AVG, :latency_ms).as(:avg_latency_ms),
                  Sequel.function(:SUM, :cost_usd).as(:cost_usd)
                )
                .group(:provider, :tier)
                .order(Sequel.desc(:request_count))
                .all
            end

            def provider_detail(provider:, period: 'day')
              since = Helpers::Queries.period_start(period)
              ::Legion::Data::DB[:metering_records]
                .where(provider: provider)
                .where { inserted_at >= since }
                .select(
                  :model_id, :request_type,
                  Sequel.function(:COUNT, Sequel.lit('*')).as(:count),
                  Sequel.function(:SUM, :total_tokens).as(:total_tokens),
                  Sequel.function(:AVG, :latency_ms).as(:avg_latency_ms),
                  Sequel.function(:SUM, :cost_usd).as(:cost_usd)
                )
                .group(:model_id, :request_type)
                .order(Sequel.desc(:count))
                .all
            end
          end
        end
      end
    end
  end
end
