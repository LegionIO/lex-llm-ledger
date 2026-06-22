# frozen_string_literal: true

require 'digest'
require 'securerandom'
require 'legion/logging'
require 'legion/data/model'

module Legion
  module Extensions
    module Llm
      module Ledger
        module Runners
          module IdentityResolution
            extend self
            extend Legion::Logging::Helper

            CANONICAL_TYPES = %i[human service system integration bot external api unknown].freeze
            CALLER_TYPE_MAP = {
              user:        :human,
              human:       :human,
              person:      :human,
              admin:       :system,
              service:     :service,
              daemon:      :service,
              worker:      :service,
              bot:         :bot,
              integration: :integration,
              external:    :external
            }.freeze

            def normalize_caller(body:, headers:)
              headers ||= {}
              caller_hash = body[:caller].is_a?(Hash) ? body[:caller] : {}
              requested_by = caller_hash[:requested_by].is_a?(Hash) ? caller_hash[:requested_by] : caller_hash
              identity_hash = body[:identity].is_a?(Hash) ? body[:identity] : {}

              raw_identity = first_present(
                headers['x-legion-identity-canonical-name'],
                identity_hash[:id], identity_hash[:canonical_name], identity_hash[:identity],
                headers['x-legion-identity'],
                requested_by[:id], requested_by[:canonical_name], requested_by[:identity]
              )

              raw_type = first_present(
                identity_hash[:type], identity_hash[:kind],
                headers['x-legion-caller-type'],
                requested_by[:type], requested_by[:kind]
              )

              {
                identity:     raw_identity&.to_s,
                type:         raw_type&.to_s,
                principal_id: integer_header(headers, 'x-legion-identity-db-principal-id'),
                identity_id:  integer_header(headers, 'x-legion-identity-db-identity-id')
              }.compact
            end

            def resolve_refs(body:, headers:)
              headers ||= {}
              normalized = normalize_caller(body: body, headers: headers)
              principal_id = normalized[:principal_id]
              identity_id = normalized[:identity_id]
              canonical = extract_canonical_name(normalized[:identity])

              unless principal_id && identity_id
                if identity_id && !principal_id && identity_tables_available?
                  row = Legion::Data::Model::Identity::Identity[identity_id]
                  principal_id = row[:principal_id] if row
                end

                unless principal_id && identity_id
                  resolved = resolve_identity_triad(canonical, normalized)
                  principal_id ||= resolved[:principal_id]
                  identity_id ||= resolved[:identity_id]
                end
              end

              { principal_id: principal_id, identity_id: identity_id, canonical_name: canonical }.compact
            end

            def identity_tables_available?
              !Legion::Data::Model::Identity::Provider.dataset.nil? &&
                !Legion::Data::Model::Identity::Principal.dataset.nil? &&
                !Legion::Data::Model::Identity::Identity.dataset.nil?
            rescue StandardError => e
              handle_exception(e, level: :debug, handled: true, operation: 'identity_resolution.tables_check')
              false
            end

            def canonical_name(body:, headers:)
              headers ||= {}
              normalized = normalize_caller(body: body, headers: headers)
              extract_canonical_name(normalized[:identity])
            end

            private

            def resolve_identity_triad(canonical, normalized)
              return {} unless canonical && identity_tables_available?

              kind          = (normalize_type(normalized[:type]) || 'unknown').to_s
              provider_name = extract_provider_name(normalized)

              provider  = find_or_create_provider(provider_name)
              principal = find_or_create_principal(canonical, kind)
              identity  = find_or_create_identity(principal, provider, canonical)

              { principal_id: principal[:id], identity_id: identity[:id] }
            rescue StandardError => e
              handle_exception(e, level: :warn, handled: true, operation: 'identity_resolution')
              {}
            end

            def find_or_create_provider(name)
              Legion::Data::Model::Identity::Provider.first(name: name) ||
                Legion::Data::Model::Identity::Provider.create(
                  uuid:          deterministic_uuid("identity_provider:#{name}"),
                  name:          name,
                  provider_type: name == 'local' ? 'local' : 'external',
                  facing:        'internal',
                  source:        'ledger',
                  created_at:    Time.now.utc,
                  updated_at:    Time.now.utc
                )
            rescue Sequel::UniqueConstraintViolation => e
              handle_exception(e, level: :debug, handled: true, operation: 'identity_resolution.provider_race')
              Legion::Data::Model::Identity::Provider.first(name: name)
            end

            def find_or_create_principal(canonical, kind)
              Legion::Data::Model::Identity::Principal.first(canonical_name: canonical, kind: kind) ||
                Legion::Data::Model::Identity::Principal.create(
                  uuid:           deterministic_uuid("identity_principal:#{kind}:#{canonical}"),
                  canonical_name: canonical,
                  kind:           kind,
                  display_name:   canonical,
                  last_seen_at:   Time.now.utc,
                  created_at:     Time.now.utc,
                  updated_at:     Time.now.utc
                )
            rescue Sequel::UniqueConstraintViolation => e
              handle_exception(e, level: :debug, handled: true, operation: 'identity_resolution.principal_race')
              Legion::Data::Model::Identity::Principal.first(canonical_name: canonical, kind: kind)
            end

            def find_or_create_identity(principal, provider, canonical)
              Legion::Data::Model::Identity::Identity.first(
                principal_id:          principal[:id],
                provider_id:           provider[:id],
                provider_identity_key: canonical
              ) || Legion::Data::Model::Identity::Identity.create(
                uuid:                  deterministic_uuid(
                  "identity:#{principal[:id]}:#{provider[:id]}:#{canonical}"
                ),
                principal_id:          principal[:id],
                provider_id:           provider[:id],
                provider_identity_key: canonical,
                last_authenticated_at: Time.now.utc,
                account_type:          'primary',
                is_default:            true,
                created_at:            Time.now.utc,
                updated_at:            Time.now.utc
              )
            rescue Sequel::UniqueConstraintViolation => e
              handle_exception(e, level: :debug, handled: true, operation: 'identity_resolution.identity_race')
              Legion::Data::Model::Identity::Identity.first(
                principal_id:          principal[:id],
                provider_id:           provider[:id],
                provider_identity_key: canonical
              )
            end

            def extract_canonical_name(raw_identity)
              text = raw_identity&.to_s
              if text&.include?(':') && !text&.include?('@')
                _prefix, remainder = text.split(':', 2)
                text = remainder if remainder && !remainder.empty?
              end
              text.nil? || text.empty? ? nil : text
            end

            def extract_provider_name(_normalized)
              'local'
            end

            def normalize_type(raw)
              sym = raw&.to_s&.to_sym
              return unless sym

              CANONICAL_TYPES.include?(sym) ? sym : CALLER_TYPE_MAP[sym]
            end

            def first_present(*values)
              values.find { |v| v && !v.to_s.strip.empty? }
            end

            def integer_header(headers, key)
              raw = headers[key] || headers[key.to_sym]
              int = raw&.to_i
              int&.positive? ? int : nil
            end

            def deterministic_uuid(value)
              hex = Digest::SHA256.hexdigest(value.to_s)[0, 32]
              "#{hex[0, 8]}-#{hex[8, 4]}-#{hex[12, 4]}-#{hex[16, 4]}-#{hex[20, 12]}"
            end
          end
        end
      end
    end
  end
end
