# frozen_string_literal: true

RSpec.describe Legion::Extensions::Llm::Ledger::Runners::RegistryAvailability do
  let(:payload) do
    {
      event_id:    'evt-123',
      event_type:  :offering_available,
      occurred_at: '2026-04-28T14:30:15.123456Z',
      offering:    {
        offering_id:           'ollama:macbook-m4-max:inference:qwen3-6',
        provider_family:       :ollama,
        provider_instance:     :'macbook-m4-max',
        instance_id:           :'macbook-m4-max',
        model_family:          :qwen,
        model:                 'qwen3.6',
        canonical_model_alias: 'qwen3',
        provider_model:        'qwen3.6:27b',
        usage_type:            :inference,
        transport:             :rabbitmq,
        capabilities:          %i[chat tools],
        limits:                { context_window: 32_768 }
      },
      runtime:     {
        worker_id: 'worker-123',
        node_id:   'node-abc',
        process:   { pid: 12_345 }
      },
      capacity:    { concurrency: 4, queued: 0 },
      health:      { ready: true, latency_ms: 180 },
      lane:        { key: 'llm.fleet.inference.qwen3-6.ctx32768', status: :available },
      metadata:    { observed_by: :lex_llm_ollama }
    }
  end

  let(:metadata) do
    {
      properties: {
        message_id:     'registry_event_123',
        correlation_id: 'evt-123',
        routing_key:    'offering.available'
      }
    }
  end

  describe '.write_registry_availability_record' do
    it 'inserts a JSON-safe provider-neutral availability record' do
      result = described_class.write_registry_availability_record(payload, metadata)
      expect(result).to eq({ result: :ok })

      row = Legion::Data::DB[:registry_availability_records].first
      expect(row[:event_id]).to eq('evt-123')
      expect(row[:message_id]).to eq('registry_event_123')
      expect(row[:correlation_id]).to eq('evt-123')
      expect(row[:routing_key]).to eq('offering.available')
      expect(row[:event_type]).to eq('offering_available')
      expect(row[:occurred_at]).to eq('2026-04-28T14:30:15.123456Z')
      expect(row[:offering_id]).to eq('ollama:macbook-m4-max:inference:qwen3-6')
      expect(row[:provider_family]).to eq('ollama')
      expect(row[:provider_instance]).to eq('macbook-m4-max')
      expect(row[:instance_id]).to eq('macbook-m4-max')
      expect(row[:model_family]).to eq('qwen')
      expect(row[:model_id]).to eq('qwen3.6')
      expect(row[:canonical_model]).to eq('qwen3')
      expect(row[:provider_model]).to eq('qwen3.6:27b')
      expect(row[:usage_type]).to eq('inference')
      expect(row[:transport]).to eq('rabbitmq')
      expect(row[:lane_key]).to eq('llm.fleet.inference.qwen3-6.ctx32768')
      expect(row[:worker_id]).to eq('worker-123')
      expect(row[:node_id]).to eq('node-abc')

      expect(JSON.parse(row[:offering_json])['provider_family']).to eq('ollama')
      expect(JSON.parse(row[:runtime_json])['process']['pid']).to eq(12_345)
      expect(JSON.parse(row[:lane_json])['status']).to eq('available')
      expect(JSON.parse(row[:metadata_json])['observed_by']).to eq('lex_llm_ollama')
    end

    it 'accepts subscription keyword envelopes with payload and metadata' do
      result = described_class.write_registry_availability_record(payload: payload, metadata: metadata)

      expect(result).to eq({ result: :ok })
      row = Legion::Data::DB[:registry_availability_records].first
      expect(row[:event_id]).to eq('evt-123')
      expect(row[:message_id]).to eq('registry_event_123')
    end

    it 'returns duplicate on second insert with same event_id' do
      described_class.write_registry_availability_record(payload, metadata)
      result = described_class.write_registry_availability_record(payload, metadata)

      expect(result).to eq({ result: :duplicate })
      expect(Legion::Data::DB[:registry_availability_records].count).to eq(1)
    end

    it 'returns error without raising when database persistence fails' do
      allow(Legion::Data::DB).to receive(:[]).with(:registry_availability_records).and_raise(Sequel::DatabaseError,
                                                                                             'database down')

      expect(described_class.write_registry_availability_record(payload, metadata)).to eq(
        { result: :error, error: 'database down' }
      )
    end
  end
end
