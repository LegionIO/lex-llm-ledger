# frozen_string_literal: true

module Legion
  module Extensions
    module LLM
      module Ledger
        module Helpers
          module Queries
            module_function

            PERIOD_SECONDS = {
              'hour'  => 3600,
              'day'   => 86_400,
              'week'  => 604_800,
              'month' => 2_592_000
            }.freeze

            def period_start(period)
              seconds = PERIOD_SECONDS.fetch(period.to_s, 86_400)
              Time.now.utc - seconds
            end

            def latency_status(avg_ms)
              return :unknown if avg_ms.nil?
              return :healthy  if avg_ms < 2_000
              return :degraded if avg_ms < 8_000

              :critical
            end

            def phi_flag?(cls, headers)
              cls[:contains_phi] == true || headers['x-legion-contains-phi'] == 'true'
            end
          end
        end
      end
    end
  end
end
