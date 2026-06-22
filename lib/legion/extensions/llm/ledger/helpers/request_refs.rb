# frozen_string_literal: true

require 'securerandom'
require_relative 'stable_identifiers'

module Legion
  module Extensions
    module Llm
      module Ledger
        module Helpers
          module RequestRefs
            extend Legion::Logging::Helper
            extend StableIdentifiers

            module_function

            # Resolve the canonical request reference for a payload body.
            # Policy: explicit request id > correlation id > generated uuid.
            # Memoized on body[:__ledger_request_ref] so the same body reuse is stable.
            def request_ref(body)
              body[:__ledger_request_ref] ||=
                explicit_request_ref(body) || correlation_id(body) || generated_request_ref(body)
            end

            # Extract an explicit request reference from the body.
            # Checks :request_id first, then :request_ref.
            def explicit_request_ref(body)
              reference(body, :request_id, :request_ref)
            end

            # Extract the correlation id from the body.
            # Checks :correlation_id and :correlation_ref first, then tracing context.
            def correlation_id(body)
              reference(body, :correlation_id, :correlation_ref) || body.dig(:tracing, :correlation_id)
            end

            # Generate a random request ref as last resort.
            # Memoized on body[:__ledger_generated_request_ref] for idempotency.
            def generated_request_ref(body)
              body[:__ledger_generated_request_ref] ||= SecureRandom.uuid
            end

            # Fallback lookup: return the first present value for the given keys.
            def reference(body, *keys)
              keys.lazy.map { |key| body[key] }.find { |value| present?(value) }&.to_s
            end

            def present?(value) # rubocop:disable Naming/PredicateName
              !value.nil? && value.to_s.strip != ''
            end
          end

          # Extend the Helpers module namespace so callers can require just one file.
          extend RequestRefs
        end
      end
    end
  end
end
