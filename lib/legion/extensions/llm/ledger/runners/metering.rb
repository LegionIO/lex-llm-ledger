# frozen_string_literal: true

require 'legion/logging'
require 'legion/data/model'
require_relative 'prompts'
require_relative 'requests'
require_relative 'metrics'

module Legion
  module Extensions
    module Llm
      module Ledger
        module Runners
          module Metering
            extend self # rubocop:disable Style/ModuleFunction
            extend Legion::Logging::Helper

            # Persist a metering record into the official lifecycle schema.
            # Delegates to Prompts.write_metering which handles conversation ->
            # request -> response -> metric without creating message rows.
            def insert(payload:, metadata: {}, **_opts)
              Runners::Prompts.write_metering(payload: payload, metadata: metadata)
            end

            # Look up a metric by request reference.
            def find(request_ref:, **_opts)
              return { result: :not_found } unless request_ref

              request = Runners::Requests.fetch(ref: request_ref)
              return { result: :not_found } unless request

              metric = Runners::Metrics.fetch(request_id: request[:id])
              return { result: :not_found } unless metric

              { result: :ok, metric: metric.to_h }
            rescue StandardError => e
              handle_exception(e, level: :warn, handled: true, operation: 'metering.find')
              { result: :error, error: e.message }
            end
          end
        end
      end
    end
  end
end
