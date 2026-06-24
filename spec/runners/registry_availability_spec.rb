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

  describe '.insert' do
    it 'inserts a JSON-safe provider-neutral availability record' do
      result = described_class.insert(payload: payload, metadata: metadata)
      expect(result).to eq({ result: :ok })

      row = Legion::Data::Models::LLM::Conversation.db[:llm_registry_availability_records].first
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
      result = described_class.insert(payload: payload, metadata: metadata)

      expect(result).to eq({ result: :ok })
      row = Legion::Data::Models::LLM::Conversation.db[:llm_registry_availability_records].first
      expect(row[:event_id]).to eq('evt-123')
      expect(row[:message_id]).to eq('registry_event_123')
    end

    it 'returns duplicate on second insert with same event_id' do
      described_class.insert(payload: payload, metadata: metadata)
      result = described_class.insert(payload: payload, metadata: metadata)

      expect(result).to eq({ result: :duplicate })
      expect(Legion::Data::Models::LLM::Conversation.db[:llm_registry_availability_records].count).to eq(1)
    end

    it 'stores nil identity_canonical_name when no identity is present in headers or body' do
      described_class.insert(payload: payload, metadata: metadata)

      row = Legion::Data::Models::LLM::Conversation.db[:llm_registry_availability_records].first
      expect(row[:identity_canonical_name]).to be_nil
    end

    it 'writes identity_canonical_name from x-legion-identity header when present' do
      metadata_with_identity = metadata.merge(
        headers: {
          'x-legion-identity'    => 'lex-llm-ollama',
          'x-legion-caller-type' => 'service',
          'x-legion-credential'  => 'local'
        }
      )
      described_class.insert(payload: payload, metadata: metadata_with_identity)

      row = Legion::Data::Models::LLM::Conversation.db[:llm_registry_availability_records].first
      expect(row[:identity_canonical_name]).to eq('lex-llm-ollama')
    end

    it 'writes identity_canonical_name from body identity block when header is absent' do
      payload_with_identity = payload.merge(
        identity: { identity: 'apollo-worker-01', type: 'service', credential: 'local' }
      )
      described_class.insert(payload: payload_with_identity, metadata: metadata)

      row = Legion::Data::Models::LLM::Conversation.db[:llm_registry_availability_records].first
      expect(row[:identity_canonical_name]).to eq('apollo-worker-01')
    end

    it 'raises when database persistence fails so the delivery can retry' do
      relation = instance_double(Sequel::Dataset)
      allow(described_class).to receive(:registry_relation).and_return(relation)
      allow(relation).to receive(:first_source).and_return(:llm_registry_availability_records)
      allow(relation).to receive(:insert).and_raise(Sequel::DatabaseError, 'database down')

      expect do
        described_class.insert(payload: payload, metadata: metadata)
      end.to raise_error(Sequel::DatabaseError, /database down/)
    end
  end

  # PRESERVATION CONTRACT — verify runtime invariants before the runner rewrite.
  describe 'preservation contract' do
    context 'kwargs contract' do
      it 'accepts kwargs entrypoints for registry writes' do
        result = described_class.insert(payload: payload, metadata: metadata, ignored: 'ok')
        expect(result[:result]).to eq(:ok)
      end
    end
  end
end
