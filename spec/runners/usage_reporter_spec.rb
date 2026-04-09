# frozen_string_literal: true

RSpec.describe Legion::Extensions::LLM::Ledger::Runners::UsageReporter do
  def insert_metering(overrides = {})
    defaults = {
      message_id:      "meter_#{SecureRandom.hex(4)}",
      correlation_id:  'req_abc',
      conversation_id: 'conv_123',
      message_id_ctx:  'msg_005',
      request_id:      'req_abc',
      request_type:    'chat',
      tier:            'fleet',
      provider:        'ollama',
      model_id:        'qwen3.5:27b',
      node_id:         'laptop-matt-01',
      worker_id:       'gpu-h100-01',
      input_tokens:    42,
      output_tokens:   28,
      thinking_tokens: 0,
      total_tokens:    70,
      latency_ms:      1245,
      wall_clock_ms:   1300,
      cost_usd:        0.05,
      recorded_at:     '2026-04-08T14:30:01.300Z',
      inserted_at:     Time.now.utc
    }
    Legion::Data::DB[:metering_records].insert(defaults.merge(overrides))
  end

  describe '.summary' do
    it 'returns aggregate data for recent records' do
      insert_metering
      insert_metering(message_id: 'meter_002', total_tokens: 100, cost_usd: 0.10)

      results = described_class.summary(period: 'day')
      expect(results.length).to eq(1)
      expect(results.first[:request_count]).to eq(2)
      expect(results.first[:grand_total_tokens]).to eq(170)
    end

    it 'groups by provider when requested' do
      insert_metering(provider: 'ollama')
      insert_metering(message_id: 'meter_002', provider: 'bedrock')

      results = described_class.summary(period: 'day', group_by: 'provider')
      expect(results.length).to eq(2)
    end
  end

  describe '.worker_usage' do
    it 'returns only records for the specified worker' do
      insert_metering(worker_id: 'gpu-h100-01')
      insert_metering(message_id: 'meter_002', worker_id: 'gpu-h100-02')

      results = described_class.worker_usage(worker_id: 'gpu-h100-01', period: 'day')
      expect(results.length).to eq(1)
      expect(results.first[:total_tokens]).to eq(70)
    end
  end

  describe '.budget_check' do
    it 'returns correct budget status' do
      insert_metering(budget_id: 'budget_q1', cost_usd: 3.0)
      insert_metering(message_id: 'meter_002', budget_id: 'budget_q1', cost_usd: 5.0)

      result = described_class.budget_check(budget_id: 'budget_q1', budget_usd: 10.0, period: 'month')
      expect(result[:spent_usd]).to eq(8.0)
      expect(result[:remaining_usd]).to eq(2.0)
      expect(result[:exceeded]).to be false
      expect(result[:threshold_reached]).to be true
    end

    it 'detects exceeded budget' do
      insert_metering(budget_id: 'budget_q1', cost_usd: 11.0)

      result = described_class.budget_check(budget_id: 'budget_q1', budget_usd: 10.0, period: 'month')
      expect(result[:exceeded]).to be true
    end
  end

  describe '.top_consumers' do
    it 'returns top N consumers by cost' do
      insert_metering(node_id: 'node-a', cost_usd: 5.0)
      insert_metering(message_id: 'meter_002', node_id: 'node-b', cost_usd: 10.0)
      insert_metering(message_id: 'meter_003', node_id: 'node-c', cost_usd: 1.0)

      results = described_class.top_consumers(limit: 2, group_by: 'node_id', period: 'day')
      expect(results.length).to eq(2)
      expect(results.first[:node_id]).to eq('node-b')
    end
  end
end
