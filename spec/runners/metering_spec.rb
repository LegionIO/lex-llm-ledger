# frozen_string_literal: true

RSpec.describe Legion::Extensions::Llm::Ledger::Runners::Metering do
  let(:payload) do
    {
      message_context: {
        conversation_id:   'conv_123',
        message_id:        'msg_005',
        parent_message_id: 'msg_004',
        message_seq:       5,
        request_id:        'req_abc',
        exchange_id:       'exch_001'
      },
      request_type:    'chat',
      tier:            'fleet',
      provider:        'ollama',
      model_id:        'qwen3.5:27b',
      node_id:         'laptop-matt-01',
      worker_id:       'gpu-h100-01',
      agent_id:        'gaia',
      task_id:         'task_abc',
      input_tokens:    42,
      output_tokens:   28,
      thinking_tokens: 0,
      total_tokens:    70,
      latency_ms:      1245,
      wall_clock_ms:   1300,
      cost_usd:        0.0,
      routing_reason:  'fleet_gpu_available',
      recorded_at:     '2026-04-08T14:30:01.300Z',
      billing:         {
        cost_center: 'engineering-platform',
        budget_id:   'budget_q1_2026'
      }
    }
  end

  let(:metadata) do
    {
      properties: {
        message_id:     'meter_abc123',
        correlation_id: 'req_abc'
      }
    }
  end

  describe '.write_metering_record' do
    it 'inserts a record and returns ok' do
      result = described_class.write_metering_record(payload, metadata)
      expect(result).to eq({ result: :ok })

      row = Legion::Data::DB[:metering_records].first
      expect(row[:message_id]).to eq('meter_abc123')
      expect(row[:correlation_id]).to eq('req_abc')
      expect(row[:conversation_id]).to eq('conv_123')
      expect(row[:message_id_ctx]).to eq('msg_005')
      expect(row[:parent_message_id]).to eq('msg_004')
      expect(row[:message_seq]).to eq(5)
      expect(row[:request_id]).to eq('req_abc')
      expect(row[:exchange_id]).to eq('exch_001')
      expect(row[:request_type]).to eq('chat')
      expect(row[:tier]).to eq('fleet')
      expect(row[:provider]).to eq('ollama')
      expect(row[:model_id]).to eq('qwen3.5:27b')
      expect(row[:node_id]).to eq('laptop-matt-01')
      expect(row[:worker_id]).to eq('gpu-h100-01')
      expect(row[:agent_id]).to eq('gaia')
      expect(row[:task_id]).to eq('task_abc')
      expect(row[:input_tokens]).to eq(42)
      expect(row[:output_tokens]).to eq(28)
      expect(row[:thinking_tokens]).to eq(0)
      expect(row[:total_tokens]).to eq(70)
      expect(row[:latency_ms]).to eq(1245)
      expect(row[:wall_clock_ms]).to eq(1300)
      expect(row[:cost_usd]).to eq(0.0)
      expect(row[:routing_reason]).to eq('fleet_gpu_available')
      expect(row[:cost_center]).to eq('engineering-platform')
      expect(row[:budget_id]).to eq('budget_q1_2026')
      expect(row[:recorded_at]).to eq('2026-04-08T14:30:01.300Z')
    end

    it 'returns duplicate on second insert with same message_id' do
      described_class.write_metering_record(payload, metadata)
      result = described_class.write_metering_record(payload, metadata)
      expect(result).to eq({ result: :duplicate })
      expect(Legion::Data::DB[:metering_records].count).to eq(1)
    end

    it 'handles nil billing block' do
      payload.delete(:billing)
      result = described_class.write_metering_record(payload, metadata)
      expect(result).to eq({ result: :ok })

      row = Legion::Data::DB[:metering_records].first
      expect(row[:cost_center]).to be_nil
      expect(row[:budget_id]).to be_nil
    end

    it 'stores zero thinking_tokens' do
      payload[:thinking_tokens] = 0
      described_class.write_metering_record(payload, metadata)
      row = Legion::Data::DB[:metering_records].first
      expect(row[:thinking_tokens]).to eq(0)
    end

    it 'converts nil token values to zero' do
      payload[:thinking_tokens] = nil
      described_class.write_metering_record(payload, metadata)
      row = Legion::Data::DB[:metering_records].first
      expect(row[:thinking_tokens]).to eq(0)
    end
  end
end
