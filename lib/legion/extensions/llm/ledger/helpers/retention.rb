# frozen_string_literal: true

require 'legion/settings'

module Legion
  module Extensions
    module Llm
      module Ledger
        module Helpers
          module Retention
            extend Legion::Settings::Helper

            PHI_TTL_DEFAULT_DAYS = 30

            RETENTION_MAP = {
              'session_only' => 0,
              'days_30'      => 30,
              'days_90'      => 90,
              'permanent'    => nil
            }.freeze

            module_function

            def resolve(retention:, contains_phi: false)
              label = retention.to_s.empty? ? 'default' : retention.to_s
              days  = days_for_label(label)
              days  = apply_phi_cap(days, contains_phi)
              days ? Time.now.utc + (days * 86_400) : nil
            end

            def expired_ids(table)
              ::Legion::Data.connection[table]
                            .where { expires_at <= Time.now.utc }
                            .select_map(:id)
            end

            def days_for_label(label)
              return default_days if label == 'default'
              return RETENTION_MAP[label] if RETENTION_MAP.key?(label)

              default_days
            end

            def apply_phi_cap(days, contains_phi)
              return days unless contains_phi

              phi_cap = phi_ttl_days
              return phi_cap if days.nil?

              [days, phi_cap].min
            end

            def default_days
              setting(:retention, :default_days, default: 90).to_i
            end

            def phi_ttl_days
              setting(:retention, :phi_ttl_days, default: PHI_TTL_DEFAULT_DAYS).to_i
            end

            def setting(*path, default:)
              value = settings_sources.lazy
                                      .map { |source| dig_setting(source, *path) }
                                      .find { |candidate| !candidate.nil? }
              return value unless value.nil?

              default
            end

            def settings_sources
              [
                dig_setting(Legion::Settings[:extensions], :llm, :ledger),
                dig_setting(settings, :ledger),
                settings
              ].compact
            end

            def dig_setting(source, *path)
              path.reduce(source) do |current, key|
                break nil unless current.respond_to?(:key?)

                current[key] || current[key.to_s]
              end
            end

            private_class_method :days_for_label, :apply_phi_cap, :default_days, :phi_ttl_days, :setting,
                                 :settings_sources, :dig_setting
          end
        end
      end
    end
  end
end
