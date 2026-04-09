# frozen_string_literal: true

RSpec.describe Legion::Extensions::LLM::Ledger::Helpers::Retention do
  describe '.resolve' do
    context 'with default retention' do
      it 'returns approximately 90 days from now' do
        result = described_class.resolve(retention: 'default', contains_phi: false)
        expect(result).to be_within(2).of(Time.now.utc + (90 * 86_400))
      end

      it 'returns 90 days when retention is nil' do
        result = described_class.resolve(retention: nil, contains_phi: false)
        expect(result).to be_within(2).of(Time.now.utc + (90 * 86_400))
      end

      it 'returns 90 days when retention is empty string' do
        result = described_class.resolve(retention: '', contains_phi: false)
        expect(result).to be_within(2).of(Time.now.utc + (90 * 86_400))
      end
    end

    context 'with permanent retention' do
      it 'returns nil for non-PHI' do
        result = described_class.resolve(retention: 'permanent', contains_phi: false)
        expect(result).to be_nil
      end

      it 'caps at PHI TTL for PHI records' do
        result = described_class.resolve(retention: 'permanent', contains_phi: true)
        expect(result).to be_within(2).of(Time.now.utc + (30 * 86_400))
      end
    end

    context 'with days_30 retention' do
      it 'returns 30 days' do
        result = described_class.resolve(retention: 'days_30', contains_phi: false)
        expect(result).to be_within(2).of(Time.now.utc + (30 * 86_400))
      end

      it 'stays at 30 days for PHI (already within cap)' do
        result = described_class.resolve(retention: 'days_30', contains_phi: true)
        expect(result).to be_within(2).of(Time.now.utc + (30 * 86_400))
      end
    end

    context 'with days_90 retention' do
      it 'returns 90 days for non-PHI' do
        result = described_class.resolve(retention: 'days_90', contains_phi: false)
        expect(result).to be_within(2).of(Time.now.utc + (90 * 86_400))
      end

      it 'caps at PHI TTL for PHI records' do
        result = described_class.resolve(retention: 'days_90', contains_phi: true)
        expect(result).to be_within(2).of(Time.now.utc + (30 * 86_400))
      end
    end

    context 'with session_only retention' do
      it 'returns nil (lifecycle driven by session close, not TTL)' do
        result = described_class.resolve(retention: 'session_only', contains_phi: false)
        expect(result).to be_nil
      end

      it 'caps at PHI TTL when PHI flagged' do
        result = described_class.resolve(retention: 'session_only', contains_phi: true)
        expect(result).to be_within(2).of(Time.now.utc + (30 * 86_400))
      end
    end

    context 'with unknown retention label' do
      it 'falls back to default_days' do
        result = described_class.resolve(retention: 'unknown_label', contains_phi: false)
        expect(result).to be_within(2).of(Time.now.utc + (90 * 86_400))
      end
    end

    context 'with settings overrides' do
      before do
        stub_const('Legion::Settings', Class.new do
          def self.respond_to?(method, *args)
            method == :dig || super
          end

          def self.dig(*keys)
            settings = { llm_ledger: { retention: { default_days: 60, phi_ttl_days: 14 } } }
            keys.reduce(settings) { |h, k| h.is_a?(Hash) ? h[k] : nil }
          end
        end)
      end

      it 'uses configured default_days' do
        result = described_class.resolve(retention: 'default', contains_phi: false)
        expect(result).to be_within(2).of(Time.now.utc + (60 * 86_400))
      end

      it 'uses configured phi_ttl_days' do
        result = described_class.resolve(retention: 'permanent', contains_phi: true)
        expect(result).to be_within(2).of(Time.now.utc + (14 * 86_400))
      end
    end
  end
end
