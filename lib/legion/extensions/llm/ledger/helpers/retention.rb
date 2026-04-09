# frozen_string_literal: true

module Legion
  module Extensions
    module Llm
      module Ledger
        module Helpers
          module Retention
            PHI_TTL_DEFAULT_DAYS = 30

            RETENTION_MAP = {
              'session_only' => nil,
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
              ::Legion::Data::DB[table]
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
              if defined?(Legion::Settings) &&
                 Legion::Settings.respond_to?(:dig) &&
                 Legion::Settings.dig(:llm_ledger, :retention, :default_days)
                Legion::Settings.dig(:llm_ledger, :retention, :default_days).to_i
              else
                90
              end
            end

            def phi_ttl_days
              if defined?(Legion::Settings) &&
                 Legion::Settings.respond_to?(:dig) &&
                 Legion::Settings.dig(:llm_ledger, :retention, :phi_ttl_days)
                Legion::Settings.dig(:llm_ledger, :retention, :phi_ttl_days).to_i
              else
                PHI_TTL_DEFAULT_DAYS
              end
            end

            private_class_method :days_for_label, :apply_phi_cap, :default_days, :phi_ttl_days
          end
        end
      end
    end
  end
end
