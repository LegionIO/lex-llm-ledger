# frozen_string_literal: true

RSpec.describe Legion::Extensions::Llm::Ledger::Runners::ProviderStats do
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
      input_tokens:    42,
      output_tokens:   28,
      thinking_tokens: 0,
      total_tokens:    70,
      latency_ms:      1000,
      wall_clock_ms:   1100,
      cost_usd:        0.0,
      recorded_at:     '2026-04-08T14:30:01.300Z',
      inserted_at:     Time.now.utc
    }
    Legion::Data::DB[:metering_records].insert(defaults.merge(overrides))
  end

  describe '.health_report' do
    it 'returns all providers with status' do
      insert_metering(provider: 'ollama', latency_ms: 500)
      insert_metering(message_id: 'meter_002', provider: 'bedrock', latency_ms: 3000)

      results = described_class.health_report
      expect(results.length).to eq(2)

      ollama = results.find { |r| r[:provider] == 'ollama' }
      expect(ollama[:status]).to eq(:healthy)

      bedrock = results.find { |r| r[:provider] == 'bedrock' }
      expect(bedrock[:status]).to eq(:degraded)
    end

    it 'returns critical for high latency' do
      insert_metering(latency_ms: 10_000)
      results = described_class.health_report
      expect(results.first[:status]).to eq(:critical)
    end
  end

  describe '.circuit_summary' do
    it 'groups by provider and tier' do
      insert_metering(provider: 'ollama', tier: 'fleet')
      insert_metering(message_id: 'meter_002', provider: 'ollama', tier: 'local')

      results = described_class.circuit_summary(period: 'day')
      expect(results.length).to eq(2)
    end
  end

  describe '.provider_detail' do
    it 'returns only rows for the specified provider' do
      insert_metering(provider: 'ollama')
      insert_metering(message_id: 'meter_002', provider: 'bedrock')

      results = described_class.provider_detail(provider: 'ollama', period: 'day')
      expect(results.length).to eq(1)
    end
  end
end
