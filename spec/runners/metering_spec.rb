# frozen_string_literal: true

RSpec.describe Legion::Extensions::Llm::Ledger::Runners::Metering do
  let(:payload) do
    {
      message_context:   {
        conversation_id:   'conv_123',
        message_id:        'msg_005',
        parent_message_id: 'msg_004',
        message_seq:       5,
        request_id:        'req_abc',
        exchange_id:       'exch_001'
      },
      request_type:      'chat',
      tier:              'fleet',
      provider:          'ollama',
      provider_instance: 'local',
      model_id:          'qwen3.5:27b',
      node_id:           'laptop-matt-01',
      worker_id:         'gpu-h100-01',
      agent_id:          'gaia',
      task_id:           'task_abc',
      input_tokens:      42,
      output_tokens:     28,
      thinking_tokens:   0,
      total_tokens:      70,
      latency_ms:        1245,
      wall_clock_ms:     1300,
      cost_usd:          0.0,
      routing_reason:    'fleet_gpu_available',
      recorded_at:       '2026-04-08T14:30:01.300Z',
      billing:           {
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
    it 'inserts official lifecycle metric rows and returns ok' do
      result = described_class.write_metering_record(payload, metadata)
      expect(result).to include(result: :ok)

      request = Legion::Data.connection[:llm_message_inference_requests].first
      response = Legion::Data.connection[:llm_message_inference_responses].first
      metric = Legion::Data.connection[:llm_message_inference_metrics].first

      expect(request[:request_ref]).to eq('req_abc')
      expect(request[:operation]).to eq('chat')
      expect(response[:provider]).to eq('ollama')
      expect(response[:provider_instance]).to eq('local')
      expect(response[:model_key]).to eq('qwen3.5:27b')
      expect(response[:dispatch_path]).to eq('fleet')
      expect(metric[:input_tokens]).to eq(42)
      expect(metric[:output_tokens]).to eq(28)
      expect(metric[:thinking_tokens]).to eq(0)
      expect(metric[:total_tokens]).to eq(70)
      expect(metric[:latency_ms]).to eq(1245)
      expect(metric[:wall_clock_ms]).to eq(1300)
      expect(metric[:cost_center]).to eq('engineering-platform')
      expect(metric[:budget_key]).to eq('budget_q1_2026')
    end

    it 'is idempotent on second insert with same message_id' do
      described_class.write_metering_record(payload, metadata)
      result = described_class.write_metering_record(payload, metadata)

      expect(result).to include(result: :ok)
      expect(Legion::Data.connection[:llm_message_inference_metrics].count).to eq(1)
    end

    it 'handles nil billing block' do
      payload.delete(:billing)
      result = described_class.write_metering_record(payload, metadata)
      expect(result).to include(result: :ok)

      row = Legion::Data.connection[:llm_message_inference_metrics].first
      expect(row[:cost_center]).to be_nil
      expect(row[:budget_key]).to be_nil
    end

    it 'stores zero thinking_tokens' do
      payload[:thinking_tokens] = 0
      described_class.write_metering_record(payload, metadata)
      row = Legion::Data.connection[:llm_message_inference_metrics].first
      expect(row[:thinking_tokens]).to eq(0)
    end

    it 'converts nil token values to zero' do
      payload[:thinking_tokens] = nil
      described_class.write_metering_record(payload, metadata)
      row = Legion::Data.connection[:llm_message_inference_metrics].first
      expect(row[:thinking_tokens]).to eq(0)
    end

    it 'normalizes caller identity from namespaced ids and current transport headers' do
      payload[:caller] = {
        requested_by: {
          id:       'system:system',
          identity: 'system',
          type:     'service'
        }
      }
      metadata[:headers] = {
        'x-legion-identity'    => 'system:system',
        'x-legion-caller-type' => 'service'
      }

      official_payload = described_class.send(
        :official_metering_payload,
        payload,
        payload[:message_context],
        metadata[:properties],
        metadata[:headers]
      )

      expect(official_payload[:caller_identity]).to eq('system:system')
      expect(official_payload[:caller_type]).to eq('service')
    end

    it 'prefers normalized event identity over ambiguous display identity' do
      payload[:caller] = { requested_by: { identity: 'system', type: 'service' } }
      payload[:identity] = { identity: 'system:system', type: 'service' }

      official_payload = described_class.send(
        :official_metering_payload,
        payload,
        payload[:message_context],
        metadata[:properties],
        metadata[:headers]
      )

      expect(official_payload[:caller_identity]).to eq('system:system')
      expect(official_payload[:caller_type]).to eq('service')
    end
  end
end
