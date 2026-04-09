# frozen_string_literal: true

RSpec.describe Legion::Extensions::LLM::Ledger::Helpers::Queries do
  describe '.period_start' do
    it 'returns approximately 1 hour ago for hour' do
      result = described_class.period_start('hour')
      expect(result).to be_within(2).of(Time.now.utc - 3600)
    end

    it 'returns approximately 1 day ago for day' do
      result = described_class.period_start('day')
      expect(result).to be_within(2).of(Time.now.utc - 86_400)
    end

    it 'returns approximately 1 week ago for week' do
      result = described_class.period_start('week')
      expect(result).to be_within(2).of(Time.now.utc - 604_800)
    end

    it 'returns approximately 30 days ago for month' do
      result = described_class.period_start('month')
      expect(result).to be_within(2).of(Time.now.utc - 2_592_000)
    end

    it 'defaults to day for unknown period' do
      result = described_class.period_start('unknown')
      expect(result).to be_within(2).of(Time.now.utc - 86_400)
    end

    it 'handles symbol input' do
      result = described_class.period_start(:hour)
      expect(result).to be_within(2).of(Time.now.utc - 3600)
    end
  end
end
