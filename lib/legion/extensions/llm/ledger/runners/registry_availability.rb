# frozen_string_literal: true

module Legion
  module Extensions
    module Llm
      module Ledger
        module Runners
          module RegistryAvailability
            extend self

            def write_registry_availability_record(payload = nil, metadata = {}, **message)
              payload, metadata = normalize_runner_args(payload, metadata, message)
              props = metadata[:properties] || {}

              body = symbolize(payload)
              record = build_registry_availability_record(body, props)
              ::Legion::Data::DB[:registry_availability_records].insert(record)
              { result: :ok }
            rescue Sequel::UniqueConstraintViolation => _e
              { result: :duplicate }
            rescue StandardError => e
              Legion::Logging.error("[lex-llm-ledger] write_registry_availability_record failed: #{e.message}") # rubocop:disable Legion/HelperMigration/DirectLogging
              { result: :error, error: e.message }
            end

            private

            def normalize_runner_args(payload, metadata, message)
              Helpers::SubscriptionMessage.runner_args(payload, metadata, message)
            end

            def build_registry_availability_record(body, props)
              offering = body[:offering] || {}
              runtime = body[:runtime] || {}
              lane = body[:lane]

              {
                event_id:          body[:event_id],
                message_id:        props[:message_id],
                correlation_id:    props[:correlation_id],
                routing_key:       props[:routing_key],
                event_type:        body[:event_type].to_s,
                occurred_at:       body[:occurred_at],
                offering_id:       offering[:offering_id],
                provider_family:   offering[:provider_family]&.to_s,
                provider_instance: offering[:provider_instance]&.to_s,
                instance_id:       offering[:instance_id]&.to_s,
                model_family:      offering[:model_family]&.to_s,
                model_id:          offering[:model],
                canonical_model:   offering[:canonical_model_alias],
                provider_model:    offering[:provider_model],
                usage_type:        offering[:usage_type]&.to_s,
                transport:         offering[:transport]&.to_s,
                lane_key:          lane_key(lane),
                worker_id:         runtime[:worker_id] || runtime[:worker],
                node_id:           runtime[:node_id] || runtime[:host_id],
                offering_json:     json_dump(offering),
                runtime_json:      json_dump(runtime),
                capacity_json:     json_dump(body[:capacity] || {}),
                health_json:       json_dump(body[:health] || {}),
                lane_json:         json_dump(lane || {}),
                metadata_json:     json_dump(body[:metadata] || {}),
                inserted_at:       Time.now.utc
              }
            end

            def lane_key(lane)
              if lane.is_a?(String)
                lane
              elsif lane.is_a?(Hash)
                lane[:key] || lane[:lane_key]
              end
            end

            def json_dump(value)
              Legion::JSON.dump(json_safe(value)) # rubocop:disable Legion/HelperMigration/DirectJson
            end

            def json_safe(value)
              case value
              when Hash
                value.to_h { |key, nested| [key.to_s, json_safe(nested)] }
              when Array
                value.map { |nested| json_safe(nested) }
              when Symbol
                value.to_s
              else
                value
              end
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
          end
        end
      end
    end
  end
end
