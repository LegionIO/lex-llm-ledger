# frozen_string_literal: true

RSpec.describe Legion::Extensions::Llm::Ledger::Runners::UsageReporter do
  def insert_metering(overrides = {})
    defaults = {
      message_id:        "meter_#{SecureRandom.hex(4)}",
      request_id:        "req_#{SecureRandom.hex(4)}",
      conversation_id:   'conv_123',
      operation:         'chat',
      tier:              'fleet',
      provider:          'ollama',
      provider_instance: 'local',
      model_id:          'qwen3.5:27b',
      input_tokens:      42,
      output_tokens:     28,
      thinking_tokens:   0,
      total_tokens:      70,
      latency_ms:        1245,
      wall_clock_ms:     1300,
      cost_usd:          0.05,
      recorded_at:       Time.now.utc,
      billing:           {
        cost_center: 'engineering-platform',
        budget_id:   'budget_q1'
      }
    }
    Legion::Extensions::Llm::Ledger::Writers::OfficialMeteringWriter.write(defaults.merge(overrides))
  end

  describe '.summary' do
    it 'returns aggregate data for recent official metric records' do
      insert_metering
      insert_metering(total_tokens: 100, cost_usd: 0.10)

      results = described_class.summary(period: 'day')
      expect(results.length).to eq(1)
      expect(results.first[:request_count]).to eq(2)
      expect(results.first[:grand_total_tokens]).to eq(170)
    end

    it 'groups by provider_instance when requested' do
      insert_metering(provider_instance: 'local')
      insert_metering(provider_instance: 'apollo')

      results = described_class.summary(period: 'day', group_by: 'provider_instance')
      expect(results.length).to eq(2)
      expect(results.map { |row| row[:provider_instance] }).to contain_exactly('local', 'apollo')
    end
  end

  describe '.worker_usage' do
    it 'treats worker_id as provider_instance for official schema compatibility' do
      insert_metering(provider_instance: 'gpu-h100-01')
      insert_metering(provider_instance: 'gpu-h100-02')

      results = described_class.worker_usage(worker_id: 'gpu-h100-01', period: 'day')
      expect(results.length).to eq(1)
      expect(results.first[:total_tokens]).to eq(70)
    end
  end

  describe '.budget_check' do
    it 'returns correct budget status from official metrics budget_key' do
      insert_metering(cost_usd: 3.0)
      insert_metering(cost_usd: 5.0)

      result = described_class.budget_check(budget_id: 'budget_q1', budget_usd: 10.0, period: 'month')
      expect(result[:spent_usd]).to eq(8.0)
      expect(result[:remaining_usd]).to eq(2.0)
      expect(result[:exceeded]).to be false
      expect(result[:threshold_reached]).to be true
    end

    it 'detects exceeded budget' do
      insert_metering(cost_usd: 11.0)

      result = described_class.budget_check(budget_id: 'budget_q1', budget_usd: 10.0, period: 'month')
      expect(result[:exceeded]).to be true
    end
  end

  describe '.top_consumers' do
    it 'returns top N provider instances by cost' do
      insert_metering(provider_instance: 'node-a', cost_usd: 5.0)
      insert_metering(provider_instance: 'node-b', cost_usd: 10.0)
      insert_metering(provider_instance: 'node-c', cost_usd: 1.0)

      results = described_class.top_consumers(limit: 2, group_by: 'provider_instance', period: 'day')
      expect(results.length).to eq(2)
      expect(results.first[:provider_instance]).to eq('node-b')
    end
  end
end
