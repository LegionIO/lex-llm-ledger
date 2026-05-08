# frozen_string_literal: true

module Legion
  module Extensions
    module Llm
      module Ledger
        module Helpers
          module CallerIdentity
            GENERIC_IDENTITIES = %w[anonymous process service system user].freeze

            module_function

            def normalize(caller_raw: nil, identity: nil, headers: {})
              caller_hash = caller_raw.is_a?(Hash) ? caller_raw : {}
              caller = hash_value(caller_hash, :requested_by)
              caller = caller_hash unless caller.is_a?(Hash)
              identity_hash = identity.is_a?(Hash) ? identity : {}
              extension = hash_value(caller_hash, :extension)
              type = first_present(
                hash_value(identity_hash, :type),
                header_value(headers, 'x-legion-caller-type'),
                hash_value(caller, :type),
                extension && 'extension'
              )

              raw_identity = first_present(
                hash_value(identity_hash, :id),
                hash_value(identity_hash, :canonical_name),
                hash_value(identity_hash, :identity),
                hash_value(identity_hash, :username),
                header_value(headers, 'x-legion-identity'),
                header_value(headers, 'x-legion-caller-identity'),
                hash_value(caller, :id),
                hash_value(caller, :canonical_name),
                hash_value(caller, :identity),
                hash_value(caller, :username),
                extension && "extension:#{extension}"
              )

              {
                identity: normalize_identity_value(raw_identity, type),
                type:     type
              }.compact
            end

            def normalize_identity_value(value, type)
              return nil unless present?(value)

              text = value.to_s
              return text if text.include?(':') || text.include?('@')
              return "#{type}:#{text}" if type && GENERIC_IDENTITIES.include?(text)

              text
            end

            def first_present(*values)
              values.find { |value| present?(value) }
            end

            def hash_value(hash, key)
              return nil unless hash.respond_to?(:key?)
              return hash[key] if hash.key?(key)

              string_key = key.to_s
              hash[string_key] if hash.key?(string_key)
            end

            def header_value(headers, key)
              return nil unless headers.respond_to?(:key?)

              headers[key] || headers[key.to_sym]
            end

            def present?(value)
              !value.nil? && !(value.respond_to?(:empty?) && value.empty?)
            end
          end
        end
      end
    end
  end
end
