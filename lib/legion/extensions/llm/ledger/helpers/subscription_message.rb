# frozen_string_literal: true

require_relative 'decryption'

module Legion
  module Extensions
    module Llm
      module Ledger
        module Helpers
          module SubscriptionMessage
            module_function

            def decode_payload(message, metadata, delivery_info)
              headers = metadata_headers(metadata)
              properties = metadata_properties(metadata)
              payload = decrypt_payload(message, headers, properties)
              body = parse_payload(payload, properties)

              {
                payload:  body,
                metadata: {
                  headers:    headers,
                  properties: properties.merge(routing_key: routing_key(delivery_info))
                }
              }
            end

            def metadata_headers(metadata)
              headers = metadata.respond_to?(:headers) ? metadata.headers : nil
              headers ||= {}
              headers.each_with_object({}) do |(key, value), normalized|
                normalized[key] = value
                normalized[key.to_s] = value unless key.is_a?(String)
              end
            end

            def metadata_properties(metadata)
              {
                content_encoding: metadata_value(metadata, :content_encoding),
                content_type:     metadata_value(metadata, :content_type),
                message_id:       metadata_value(metadata, :message_id),
                correlation_id:   metadata_value(metadata, :correlation_id),
                app_id:           metadata_value(metadata, :app_id),
                timestamp:        metadata_value(metadata, :timestamp)
              }.compact
            end

            def decrypt_payload(message, headers, properties)
              return message unless properties[:content_encoding] == 'encrypted/cs'

              iv = headers['iv'] || headers[:iv]
              raise DecryptionFailed, 'Encrypted audit record is missing iv header' if iv.nil?

              Legion::Crypt.decrypt(message, iv)
            end

            def parse_payload(payload, properties)
              return payload unless properties[:content_type] == 'application/json'

              if json_load_keyword?(:symbolize_keys)
                Legion::JSON.load(payload, symbolize_keys: true) # rubocop:disable Legion/HelperMigration/DirectJson
              else
                Legion::JSON.load(payload, symbolize_names: true) # rubocop:disable Legion/HelperMigration/DirectJson
              end
            end

            def runner_args(payload, metadata, message)
              message.key?(:payload) ? [message[:payload], message[:metadata] || {}] : [payload, metadata]
            end

            def routing_key(delivery_info)
              return delivery_info[:routing_key] if delivery_info.respond_to?(:[])
              return delivery_info.routing_key if delivery_info.respond_to?(:routing_key)

              nil
            end

            def metadata_value(metadata, key)
              return metadata.public_send(key) if metadata.respond_to?(key)
              return metadata[key] if metadata.respond_to?(:[]) && metadata_key?(metadata, key)

              nil
            end

            def metadata_key?(metadata, key)
              return metadata.key?(key) if metadata.respond_to?(:key?)
              return metadata.members.include?(key) if metadata.respond_to?(:members)

              true
            end

            def symbolize(value)
              case value
              when Hash
                value.to_h { |key, nested| [key.to_sym, symbolize(nested)] }
              when Array
                value.map { |nested| symbolize(nested) }
              else
                value
              end
            end

            def json_load_keyword?(keyword)
              Legion::JSON.method(:load).parameters.any? { |type, name| type == :key && name == keyword }
            end

            private_class_method :metadata_headers, :metadata_properties, :decrypt_payload, :parse_payload,
                                 :routing_key, :metadata_value, :metadata_key?, :symbolize, :json_load_keyword?
          end
        end
      end
    end
  end
end
