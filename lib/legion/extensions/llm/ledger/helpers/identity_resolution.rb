# frozen_string_literal: true

require 'legion/logging'
require_relative 'stable_identifiers'

module Legion
  module Extensions
    module Llm
      module Ledger
        module Helpers
          # Shared helpers used by IdentityResolution and other modules.
          module IdentityUtils
            extend self

            def present?(value) # rubocop:disable Naming/PredicateName
              !value.nil? && value.to_s.strip != ''
            end

            def integer_or_nil(value)
              return nil unless value

              integer(value)
            rescue ArgumentError, TypeError
              nil
            end

            def integer(value)
              val = value.to_s.gsub(/[^0-9]/, '')
              val.empty? ? nil : val.to_i
            end

            def normalize_provider_name(name)
              return 'local' unless present?(name)
              (name.to_s.sub(/\A.+:/, '') rescue name.to_s).sub(/\A:+/, '').downcase
            end
          end

          module IdentityResolution
            extend Legion::Logging::Helper
            extend StableIdentifiers
            extend IdentityUtils

            module_function

            # Resolve caller identity references (principal_id and identity_id) from a body.
            # Checks for explicit IDs first, then resolves through the descriptor chain.
            # Memoized on body[:__ledger_caller_identity_refs] for idempotency.
            def caller_identity_refs(db, body)
              body[:__ledger_caller_identity_refs] ||= resolve_refs(db, body)
            end

            # Extract the canonical identity name string from a body.
            def identity_canonical_name(body)
              raw = body.dig(:identity, :canonical_name) ||
                    body.dig(:identity, :identity) ||
                    body[:caller_identity]
              return nil unless raw && !raw.to_s.empty?

              raw.to_s
            end

            # Normalize the caller type to a canonical value.
            def normalize_caller_type(value)
              return nil unless IdentityUtils.present?(value)

              normalized = value.to_s.to_sym
              return normalized if CANONICAL_TYPES.include?(normalized)

              mapped = CALLER_TYPE_MAP[normalized]
              mapped || (IdentityUtils.present?(normalized.to_s) ? normalized : nil)
            end

            # Check if the identity tables (providers, principals, identities) exist.
            def identity_tables_available?(db)
              db.table_exists?(:identity_providers) &&
                db.table_exists?(:identity_principals) &&
                db.table_exists?(:identities)
            end

            # Parse a raw identity string into a structured descriptor.
            def parsed_identity_descriptor(body)
              raw_identity = body[:caller_identity] ||
                             body.dig(:identity, :identity) ||
                             body.dig(:identity, :canonical_name) ||
                             body.dig(:caller, :requested_by, :identity) ||
                             body.dig(:caller, :requested_by, :canonical_name) ||
                             body.dig(:caller, :requested_by, :id)
              return {} unless IdentityUtils.present?(raw_identity)

              raw_type = body[:caller_type] ||
                         body.dig(:identity, :type) ||
                         body.dig(:caller, :requested_by, :type) ||
                         body.dig(:caller, :source)
              provider_name = body.dig(:identity, :credential) ||
                              body.dig(:caller, :requested_by, :credential) ||
                              'local'
              parse_identity_descriptor(raw_identity, raw_type, provider_name)
            end

            # Resolve an identity through the IDENTITY_TRIAD (provider → principal → identity).
            # Returns { principal_id: ..., identity_id: ... } or {} if not resolvable.
            def resolve_identity(db, body)
              return {} unless identity_tables_available?(db)

              descriptor = parsed_identity_descriptor(body)
              return {} unless IdentityUtils.present?(descriptor[:canonical_name])

              provider = find_or_create_identity_provider(db, descriptor[:provider_name])
              principal = find_or_create_identity_principal(db, descriptor)
              identity = find_or_create_identity(db, principal, provider, descriptor)

              { principal_id: principal[:id], identity_id: identity[:id] }
            rescue StandardError => e
              handle_exception(e, level: :warn, handled: true, operation: 'identity_resolution')
              {}
            end

            # Lookup helpers using Legion::Data::Model::Identity models.
            def find_or_create_identity_provider(db, provider_name)
              existing = ::Legion::Data::Model::Identity::Provider.first(name: provider_name)
              return existing if existing

              insert_provider_with_savepoint(db, provider_name)
            rescue Sequel::UniqueConstraintViolation
              ::Legion::Data::Model::Identity::Provider.first(name: provider_name)
            end

            def find_or_create_identity_principal(db, descriptor)
              existing = ::Legion::Data::Model::Identity::Principal.first(
                canonical_name: descriptor[:canonical_name],
                kind: descriptor[:kind]
              )
              return existing if existing

              insert_principal_with_savepoint(db, descriptor)
            rescue Sequel::UniqueConstraintViolation
              ::Legion::Data::Model::Identity::Principal.first(
                canonical_name: descriptor[:canonical_name],
                kind: descriptor[:kind]
              )
            end

            def find_or_create_identity(db, principal, provider, descriptor)
              existing = ::Legion::Data::Model::Identity::Identity.first(
                principal_id: principal[:id],
                provider_id: provider[:id],
                provider_identity_key: descriptor[:provider_identity_key]
              )
              return existing if existing

              insert_identity_with_savepoint(db, principal, provider, descriptor)
            rescue Sequel::UniqueConstraintViolation
              ::Legion::Data::Model::Identity::Identity.first(
                principal_id: principal[:id],
                provider_id: provider[:id],
                provider_identity_key: descriptor[:provider_identity_key]
              )
            end

            # Savepoint-wrapped inserts for collision-safe identity writes.
            def insert_with_savepoint(db, table, attrs)
              id = db[table].insert(**attrs)
              id
            rescue Sequel::UniqueConstraintViolation
              raise
            end

            def insert_provider_with_savepoint(db, provider_name)
              attrs = {
                uuid:          deterministic_uuid("identity_provider:#{provider_name}"),
                name:          provider_name,
                provider_type: provider_name == 'local' ? 'local' : 'external',
                facing:        'internal',
                source:        'ledger',
                created_at:    Time.now.utc,
                updated_at:    Time.now.utc
              }
              db[:identity_providers].insert(**attrs)
            end

            def insert_principal_with_savepoint(db, descriptor)
              attrs = {
                uuid:           deterministic_uuid("identity_principal:#{descriptor[:kind]}:#{descriptor[:canonical_name]}"),
                canonical_name: descriptor[:canonical_name],
                kind:           descriptor[:kind],
                display_name:   descriptor[:canonical_name],
                last_seen_at:   Time.now.utc,
                created_at:     Time.now.utc,
                updated_at:     Time.now.utc
              }
              db[:identity_principals].insert(**attrs)
            end

            def insert_identity_with_savepoint(db, principal, provider, descriptor)
              attrs = {
                uuid:                  deterministic_uuid(
                  "identity:#{principal[:id]}:#{provider[:id]}:#{descriptor[:provider_identity_key]}"
                ),
                principal_id:          principal[:id],
                provider_id:           provider[:id],
                provider_identity_key: descriptor[:provider_identity_key],
                last_authenticated_at: Time.now.utc,
                account_type:          'primary',
                is_default:            true,
                created_at:            Time.now.utc,
                updated_at:            Time.now.utc
              }
              db[:identities].insert(**attrs)
            end

            private_class_method :insert_with_savepoint, :insert_provider_with_savepoint,
                                 :insert_principal_with_savepoint, :insert_identity_with_savepoint

            CANONICAL_TYPES = %i[human service system integration bot external api unknown].freeze
            CALLER_TYPE_MAP = {
              user: :human,
              human: :human,
              person: :human,
              admin: :system,
              service: :service,
              daemon: :service,
              worker: :service,
              bot: :bot,
              integration: :integration,
              external: :external
            }.freeze

            def resolve_refs(db, body)
              explicit_identity_id = IdentityUtils.integer_or_nil(body[:caller_identity_id] || body.dig(:caller, :requested_by, :id))
              explicit_principal_id = IdentityUtils.integer_or_nil(body[:caller_principal_id] ||
                                                     body.dig(:caller, :requested_by, :principal_id))

              explicit_identity_id ||= IdentityUtils.integer_or_nil(body[:__header_identity_id])
              explicit_principal_id ||= IdentityUtils.integer_or_nil(body[:__header_principal_id])

              refs = { principal_id: explicit_principal_id, identity_id: explicit_identity_id }.compact
              unless refs[:principal_id] && refs[:identity_id]
                if explicit_identity_id && !explicit_principal_id && identity_tables_available?(db)
                  row = db[:identities].where(id: explicit_identity_id).first
                  refs[:principal_id] = row[:principal_id] if row
                end

                resolved = resolve_identity(db, body)
                refs[:principal_id] ||= resolved[:principal_id]
                refs[:identity_id] ||= resolved[:identity_id]
              end
              refs.compact
            end

            def parse_identity_descriptor(raw_identity, raw_type, provider_name)
              text = raw_identity.to_s
              kind = normalize_caller_type(raw_type)
              canonical = text

              if text.include?(':') && !text.include?('@')
                prefix, remainder = text.split(':', 2)
                prefix_kind = normalize_caller_type(prefix)
                if prefix_kind && IdentityUtils.present?(remainder)
                  kind ||= prefix_kind
                  canonical = remainder
                end
              end

              {
                canonical_name:        canonical,
                kind:                  kind || 'unknown',
                provider_identity_key: text,
                provider_name:         IdentityUtils.normalize_provider_name(provider_name)
              }
            end

            private_class_method :resolve_refs, :parse_identity_descriptor
          end
        end
      end
    end
  end
end
