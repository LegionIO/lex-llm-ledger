# frozen_string_literal: true

require 'legion/json'

module Legion
  module Extensions
    module Llm
      module Ledger
        module Helpers
          module Json
            extend Legion::JSON::Helper

            module_function

            def dump(value, pretty: false)
              return 'null' if value.nil?

              json_dump(value, pretty:)
            end

            def load(value, symbolize_keys: true)
              if load_keyword?(:symbolize_keys)
                json_load(value, symbolize_keys:)
              elsif load_keyword?(:symbolize_names)
                json_load(value, symbolize_names: symbolize_keys)
              else
                json_load(value)
              end
            end

            def parse_error?(error)
              defined?(Legion::JSON::ParseError) && error.is_a?(Legion::JSON::ParseError)
            end

            def load_keyword?(keyword)
              Legion::JSON.method(:load).parameters.any? { |type, name| type == :key && name == keyword }
            end

            private_class_method :load_keyword?
          end
        end
      end
    end
  end
end
