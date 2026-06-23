# frozen_string_literal: true

RSpec.describe Legion::Extensions::Llm::Ledger::Runners::Metrics do
  let(:db) { Legion::Data::Models::LLM::MessageInferenceMetric.db }

  let(:conversation) do
    db[:llm_conversations].insert(
      uuid:             'metric-spec-conv-uuid',
      retention_policy: 'default',
      inserted_at:      Time.now.utc,
      created_at:       Time.now.utc,
      updated_at:       Time.now.utc
    )
  end

  let(:request) do
    db[:llm_message_inference_requests].insert(
      uuid:            'metric-spec-req-uuid',
      conversation_id: conversation,
      request_type:    'chat',
      status:          'created',
      inserted_at:     Time.now.utc
    )
  end

  let(:response) do
    db[:llm_message_inference_responses].insert(
      uuid:                         'metric-spec-resp-uuid',
      message_inference_request_id: request,
      status:                       'created',
      inserted_at:                  Time.now.utc
    )
  end

  def insert_metric(uuid:)
    db[:llm_message_inference_metrics].insert(
      uuid:                         uuid,
      message_inference_request_id: request,
      inserted_at:                  Time.now.utc
    )
  end

  describe '.fetch' do
    context 'by id' do
      it 'returns the metric record' do
        id = insert_metric(uuid: 'fetch-metric-by-id-uuid')
        record = described_class.fetch(id: id)
        expect(record).not_to be_nil
        expect(record[:uuid]).to eq('fetch-metric-by-id-uuid')
      end

      it 'returns nil when id does not exist' do
        expect(described_class.fetch(id: 999_999)).to be_nil
      end
    end

    context 'by uuid' do
      it 'returns the metric record' do
        insert_metric(uuid: 'fetch-metric-by-uuid-target')
        record = described_class.fetch(uuid: 'fetch-metric-by-uuid-target')
        expect(record).not_to be_nil
        expect(record[:uuid]).to eq('fetch-metric-by-uuid-target')
      end

      it 'returns nil when uuid does not exist' do
        expect(described_class.fetch(uuid: 'no-such-metric-uuid')).to be_nil
      end
    end

    context 'by request_id' do
      it 'returns the metric linked to the given request id' do
        insert_metric(uuid: 'fetch-metric-by-req-id-uuid')
        record = described_class.fetch(request_id: request)
        expect(record).not_to be_nil
        expect(record[:message_inference_request_id]).to eq(request)
      end

      it 'returns nil when no metric matches the request_id' do
        expect(described_class.fetch(request_id: 999_999)).to be_nil
      end
    end

    context 'with no arguments' do
      it 'returns nil' do
        expect(described_class.fetch).to be_nil
      end
    end
  end

  describe '.find_or_create' do
    it 'creates a new metric when one does not exist' do
      uuid = 'find-or-create-metric-new-uuid'
      record = described_class.find_or_create(
        uuid:  uuid,
        attrs: { message_inference_request_id: request }
      )
      expect(record).not_to be_nil
      expect(record[:uuid]).to eq(uuid)
      expect(db[:llm_message_inference_metrics].where(uuid: uuid).count).to eq(1)
    end

    it 'returns the existing metric on second call (idempotent)' do
      uuid = 'find-or-create-metric-idempotent-uuid'
      first = described_class.find_or_create(
        uuid:  uuid,
        attrs: { message_inference_request_id: request }
      )
      second = described_class.find_or_create(
        uuid:  uuid,
        attrs: { message_inference_request_id: request }
      )

      expect(second[:id]).to eq(first[:id])
      expect(db[:llm_message_inference_metrics].where(uuid: uuid).count).to eq(1)
    end

    it 'merges supplied attrs into the created record' do
      uuid = 'find-or-create-metric-attrs-uuid'
      record = described_class.find_or_create(
        uuid:  uuid,
        attrs: {
          message_inference_request_id: request,
          input_tokens:                 42,
          output_tokens:                28,
          total_tokens:                 70
        }
      )
      expect(record[:input_tokens]).to eq(42)
      expect(record[:output_tokens]).to eq(28)
      expect(record[:total_tokens]).to eq(70)
    end
  end
end
