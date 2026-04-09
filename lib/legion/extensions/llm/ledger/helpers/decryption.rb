# frozen_string_literal: true

module Legion
  module Extensions
    module Llm
      module Ledger
        module Helpers
          module Decryption
            module_function

            def decrypt_if_needed(payload, metadata = {})
              encoding = metadata.dig(:properties, :content_encoding).to_s

              return symbolize(payload) unless encoding == 'encrypted/cs'

              ensure_crypt_available!
              perform_decryption(payload, metadata)
            end

            def perform_decryption(payload, metadata)
              raw       = payload.is_a?(String) ? payload : Legion::JSON.dump(payload) # rubocop:disable Legion/HelperMigration/DirectJson
              init_vec  = metadata.dig(:headers, :iv) || metadata.dig(:headers, 'iv')
              decrypted = Legion::Crypt.decrypt(raw, init_vec)
              Legion::JSON.load(decrypted, symbolize_names: true) # rubocop:disable Legion/HelperMigration/DirectJson
            rescue Legion::Crypt::DecryptionError => e
              raise DecryptionFailed, "Failed to decrypt audit record: #{e.message}"
            end

            def ensure_crypt_available!
              return if defined?(Legion::Crypt) && Legion::Crypt.respond_to?(:decrypt)

              raise DecryptionUnavailable, 'Legion::Crypt is required to read encrypted audit records'
            end

            def symbolize(hash)
              return hash if hash.is_a?(Hash) && hash.keys.first.is_a?(Symbol)

              Legion::JSON.load(Legion::JSON.dump(hash), symbolize_names: true) # rubocop:disable Legion/HelperMigration/DirectJson
            end

            private_class_method :perform_decryption, :ensure_crypt_available!, :symbolize
          end

          class DecryptionFailed < StandardError; end
          class DecryptionUnavailable < StandardError; end
        end
      end
    end
  end
end
