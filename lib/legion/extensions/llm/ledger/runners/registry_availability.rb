# frozen_string_literal: true

require 'legion/data/model'
require_relative '../helpers/caller_identity'
require_relative '../helpers/identity_resolution'
require_relative '../helpers/json'

module Legion
  module Extensions
    module Llm
      module Ledger
        module Runners
          module RegistryAvailability
            extend self

            def insert(payload:, metadata: {}, **_opts)
              headers = Helpers::SubscriptionMessage.extract_headers(payload, metadata)
              props   = metadata[:properties] || {}

              body = symbolize(payload)
              record = build_registry_availability_record(body, props, headers)
              registry_relation.insert(record)
              log.info("[ledger] registry_availability.insert event_id=#{record[:event_id]}")
              { result: :ok }
            rescue Sequel::UniqueConstraintViolation => e
              handle_exception(e, level: :debug, handled: true, operation: 'registry_availability.insert_race')
              { result: :duplicate }
            rescue StandardError => e
              handle_exception(e, level: :error, handled: true, operation: 'registry_availability.insert')
              raise
            end

            alias write_registry_availability_record insert

            private

            def build_registry_availability_record(body, props, headers)
              offering = body[:offering] || {}
              runtime = body[:runtime] || {}
              lane = body[:lane]

              {
                event_id:                body[:event_id],
                message_id:              props[:message_id],
                correlation_id:          props[:correlation_id],
                routing_key:             props[:routing_key],
                event_type:              body[:event_type].to_s,
                occurred_at:             body[:occurred_at],
                offering_id:             offering[:offering_id],
                provider_family:         offering[:provider_family]&.to_s,
                provider_instance:       offering[:provider_instance]&.to_s,
                instance_id:             offering[:instance_id]&.to_s,
                model_family:            offering[:model_family]&.to_s,
                model_id:                offering[:model],
                canonical_model:         offering[:canonical_model_alias],
                provider_model:          offering[:provider_model],
                usage_type:              offering[:usage_type]&.to_s,
                transport:               offering[:transport]&.to_s,
                lane_key:                lane_key(lane),
                worker_id:               runtime[:worker_id] || runtime[:worker],
                node_id:                 runtime[:node_id] || runtime[:host_id],
                identity_canonical_name: extract_canonical_name(body, headers),
                identity_principal_id:   extract_identity_principal_id(body, headers),
                identity_id:             extract_identity_id(body, headers),
                offering_json:           json_dump(offering),
                runtime_json:            json_dump(runtime),
                capacity_json:           json_dump(body[:capacity] || {}),
                health_json:             json_dump(body[:health] || {}),
                lane_json:               json_dump(lane || {}),
                metadata_json:           json_dump(body[:metadata] || {}),
                inserted_at:             Time.now.utc
              }
            end

            def extract_canonical_name(body, headers)
              raw = headers['x-legion-identity'] ||
                    body.dig(:identity, :identity) ||
                    body.dig(:identity, :canonical_name)
              raw.to_s unless raw.nil? || raw.to_s.empty?
            end

            def extract_identity_principal_id(body, headers)
              raw = extract_canonical_name(body, headers)
              if raw && Helpers::IdentityResolution.identity_tables_available?
                body_with_identity = body.merge(caller_identity: raw)
                Helpers::IdentityResolution.resolve_identity(body_with_identity)[:principal_id]
              end
            rescue StandardError => e
              handle_exception(e, level: :warn, handled: true, operation: 'registry_availability.identity_principal')
              nil
            end

            def extract_identity_id(body, headers)
              raw = extract_canonical_name(body, headers)
              if raw && Helpers::IdentityResolution.identity_tables_available?
                body_with_identity = body.merge(caller_identity: raw)
                Helpers::IdentityResolution.resolve_identity(body_with_identity)[:identity_id]
              end
            rescue StandardError => e
              handle_exception(e, level: :warn, handled: true, operation: 'registry_availability.identity')
              nil
            end

            def lane_key(lane)
              if lane.is_a?(String)
                lane
              elsif lane.is_a?(Hash)
                lane[:key] || lane[:lane_key]
              end
            end

            def json_dump(value)
              Helpers::Json.dump(json_safe(value))
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

            def registry_relation
              Legion::Data::Models::LLM::Conversation.dataset.from(:llm_registry_availability_records)
            end

            include Legion::Extensions::Helpers::Lex if Legion::Extensions.const_defined?(:Helpers, false) &&
                                                        Legion::Extensions::Helpers.const_defined?(:Lex, false)
          end
        end
      end
    end
  end
end
