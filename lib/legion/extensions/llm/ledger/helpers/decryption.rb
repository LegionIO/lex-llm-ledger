# frozen_string_literal: true

require_relative 'json'

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

              ensure_iv!(metadata)
              ensure_crypt_available!
              perform_decryption(payload, metadata)
            end

            def perform_decryption(payload, metadata)
              raw       = payload.is_a?(String) ? payload : Json.dump(payload)
              init_vec  = metadata.dig(:headers, :iv) || metadata.dig(:headers, 'iv')
              decrypted = Legion::Crypt.decrypt(raw, init_vec)
              Json.load(decrypted)
            rescue StandardError => e
              raise if e.is_a?(DecryptionFailed) || e.is_a?(DecryptionUnavailable)

              raise DecryptionFailed, "Failed to decrypt audit record: #{e.message}"
            end

            def ensure_iv!(metadata)
              init_vec = metadata.dig(:headers, :iv) || metadata.dig(:headers, 'iv')
              return unless init_vec.nil?

              raise DecryptionFailed, 'Encrypted audit record is missing iv header'
            end

            def ensure_crypt_available!
              return if defined?(Legion::Crypt) && Legion::Crypt.respond_to?(:decrypt)

              raise DecryptionUnavailable, 'Legion::Crypt is required to read encrypted audit records'
            end

            def symbolize(hash)
              return hash if hash.is_a?(Hash) && hash.keys.first.is_a?(Symbol)

              Json.load(Json.dump(hash))
            end

            private_class_method :perform_decryption, :ensure_iv!, :ensure_crypt_available!, :symbolize
          end

          class DecryptionFailed < StandardError; end
          class DecryptionUnavailable < StandardError; end
        end
      end
    end
  end
end
