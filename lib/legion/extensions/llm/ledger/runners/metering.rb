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
            extend self
            extend Legion::Logging::Helper

            # Persist a metering record into the official lifecycle schema.
            # Delegates to Prompts.write_metering which handles conversation ->
            # request -> response -> metric without creating message rows.
            #
            # Accepts either kwargs-style (payload:, metadata:) for direct calls
            # or a flat message hash from the Subscription actor dispatch.
            def insert(payload: nil, metadata: nil, **message)
              if payload
                Runners::Prompts.write_metering(payload: payload, metadata: metadata || {})
              else
                Runners::Prompts.write_metering(payload: message, metadata: { headers: extract_headers(message) })
              end
            end

            private

            def extract_headers(message)
              message.each_with_object({}) do |(key, value), hdrs|
                str = key.to_s
                hdrs[str] = value if str.start_with?('x-legion-') || str == 'legion_protocol_version'
              end
            end

            public

            # Look up a metric by request reference.
            def find(request_ref:, **)
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
