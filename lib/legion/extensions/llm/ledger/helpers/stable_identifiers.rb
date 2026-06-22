# frozen_string_literal: true

require 'digest'

module Legion
  module Extensions
    module Llm
      module Ledger
        module Helpers
          module StableIdentifiers
            extend self

            # Derive a stable UUID from any string value.
            # If the string is already a valid UUID (<=36 chars), return as-is.
            # Otherwise, SHA-256 hash and format as RFC 4122 UUID.
            def stable_uuid(value)
              raw = value.to_s
              return raw if raw.length <= 36

              format_uuid(Digest::SHA256.hexdigest(raw)[0, 32])
            end

            # Always derive a UUID via SHA-256, regardless of the input format.
            # Unlike stable_uuid, this never passes through verbatim strings.
            def deterministic_uuid(value)
              format_uuid(Digest::SHA256.hexdigest(value.to_s)[0, 32])
            end

            private

            def format_uuid(hex32)
              "#{hex32[0, 8]}-#{hex32[8, 4]}-#{hex32[12, 4]}-#{hex32[16, 4]}-#{hex32[20, 12]}"
            end
          end
        end
      end
    end
  end
end
