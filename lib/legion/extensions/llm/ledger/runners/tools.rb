# frozen_string_literal: true

require_relative '../helpers/tool_persistence'

module Legion
  module Extensions
    module Llm
      module Ledger
        module Runners
          module Tools
            module_function

            def insert(payload:, metadata: {}, **_opts)
              headers = Helpers::SubscriptionMessage.extract_headers(payload, metadata)
              props   = metadata[:properties] || {}

              body = payload.is_a?(Hash) ? payload : Helpers::Decryption.decrypt_if_needed(payload, metadata)
              ctx  = body[:message_context] || {}
              tool = body[:tool_call] || {}

              response = Helpers::ToolPersistence.find_or_resolve_response_with_retry(body, ctx, props, headers)
              Helpers::ToolPersistence.write_tool_record(body, headers, ctx, props, tool, response)
            rescue Sequel::UniqueConstraintViolation => e
              handle_exception(e, level: :debug, handled: true, operation: 'tools.insert_race')
              { result: :duplicate }
            rescue Helpers::DecryptionUnavailable => e
              handle_exception(e, level: :warn, handled: true, operation: 'tools.insert.decrypt')
              raise
            rescue Helpers::DecryptionFailed => e
              handle_exception(e, level: :error, handled: true, operation: 'tools.insert.decrypt')
              raise
            rescue StandardError => e
              handle_exception(e, level: :error, handled: true, operation: 'tools.insert')
              raise
            end

            alias write_tool_record insert

            include Legion::Extensions::Helpers::Lex if Legion::Extensions.const_defined?(:Helpers, false) &&
                                                        Legion::Extensions::Helpers.const_defined?(:Lex, false)
          end
        end
      end
    end
  end
end
