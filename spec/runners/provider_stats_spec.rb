# frozen_string_literal: true

RSpec.describe Legion::Extensions::Llm::Ledger::Runners::ProviderStats do
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
      latency_ms:        1000,
      wall_clock_ms:     1100,
      cost_usd:          0.0,
      recorded_at:       Time.now.utc
    }
    Legion::Extensions::Llm::Ledger::Runners::Metering.insert(payload: defaults.merge(overrides), metadata: {})
  end

  describe '.health_report' do
    it 'returns all provider instances with status from official metrics' do
      insert_metering(provider: 'ollama', provider_instance: 'local', latency_ms: 500)
      insert_metering(provider: 'bedrock', provider_instance: 'east', latency_ms: 3000)

      results = described_class.health_report
      expect(results.length).to eq(2)

      ollama = results.find { |r| r[:provider] == 'ollama' && r[:provider_instance] == 'local' }
      expect(ollama[:status]).to eq(:healthy)

      bedrock = results.find { |r| r[:provider] == 'bedrock' && r[:provider_instance] == 'east' }
      expect(bedrock[:status]).to eq(:degraded)
    end

    it 'returns critical for high latency' do
      insert_metering(latency_ms: 10_000)
      results = described_class.health_report
      expect(results.first[:status]).to eq(:critical)
    end
  end

  describe '.circuit_summary' do
    it 'groups by provider, provider instance, model, operation, and tier' do
      insert_metering(provider: 'ollama', provider_instance: 'local', tier: 'fleet')
      insert_metering(provider: 'ollama', provider_instance: 'apollo', tier: 'fleet')

      results = described_class.circuit_summary(period: 'day')
      expect(results.length).to eq(2)
      expect(results.map { |row| row[:provider_instance] }).to contain_exactly('local', 'apollo')
    end
  end

  describe '.provider_detail' do
    it 'returns only rows for the specified provider grouped by official dimensions' do
      insert_metering(provider: 'ollama', provider_instance: 'local')
      insert_metering(provider: 'bedrock', provider_instance: 'east')

      results = described_class.provider_detail(provider: 'ollama', period: 'day')
      expect(results.length).to eq(1)
      expect(results.first[:provider]).to eq('ollama')
      expect(results.first[:operation]).to eq('chat')
    end
  end
end
