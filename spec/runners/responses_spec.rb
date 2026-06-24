# frozen_string_literal: true

RSpec.describe Legion::Extensions::Llm::Ledger::Runners::Responses do
  let(:db) { Legion::Data::Models::LLM::MessageInferenceResponse.db }

  let(:conversation) do
    db[:llm_conversations].insert(
      uuid:             'resp-spec-conv-uuid',
      retention_policy: 'default',
      inserted_at:      Time.now.utc,
      created_at:       Time.now.utc,
      updated_at:       Time.now.utc
    )
  end

  let(:request) do
    db[:llm_message_inference_requests].insert(
      uuid:            'resp-spec-req-uuid',
      conversation_id: conversation,
      request_type:    'chat',
      status:          'created',
      inserted_at:     Time.now.utc
    )
  end

  def insert_response(uuid:)
    db[:llm_message_inference_responses].insert(
      uuid:                         uuid,
      message_inference_request_id: request,
      status:                       'created',
      inserted_at:                  Time.now.utc
    )
  end

  describe '.fetch' do
    context 'by id' do
      it 'returns the response record' do
        id = insert_response(uuid: 'fetch-resp-by-id-uuid')
        record = described_class.fetch(id: id)
        expect(record).not_to be_nil
        expect(record[:uuid]).to eq('fetch-resp-by-id-uuid')
      end

      it 'returns nil when id does not exist' do
        expect(described_class.fetch(id: 999_999)).to be_nil
      end
    end

    context 'by uuid' do
      it 'returns the response record' do
        insert_response(uuid: 'fetch-resp-by-uuid-target')
        record = described_class.fetch(uuid: 'fetch-resp-by-uuid-target')
        expect(record).not_to be_nil
        expect(record[:uuid]).to eq('fetch-resp-by-uuid-target')
      end

      it 'returns nil when uuid does not exist' do
        expect(described_class.fetch(uuid: 'no-such-resp-uuid')).to be_nil
      end
    end

    context 'by request_id' do
      it 'returns the response linked to the given request id' do
        insert_response(uuid: 'fetch-resp-by-req-id-uuid')
        record = described_class.fetch(request_id: request)
        expect(record).not_to be_nil
        expect(record[:message_inference_request_id]).to eq(request)
      end

      it 'returns nil when no response matches the request_id' do
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
    it 'creates a new response when one does not exist' do
      uuid = 'find-or-create-resp-new-uuid'
      record = described_class.find_or_create(
        uuid:  uuid,
        attrs: { message_inference_request_id: request, status: 'created' }
      )
      expect(record).not_to be_nil
      expect(record[:uuid]).to eq(uuid)
      expect(db[:llm_message_inference_responses].where(uuid: uuid).count).to eq(1)
    end

    it 'returns the existing response on second call (idempotent)' do
      uuid = 'find-or-create-resp-idempotent-uuid'
      first = described_class.find_or_create(
        uuid:  uuid,
        attrs: { message_inference_request_id: request, status: 'created' }
      )
      second = described_class.find_or_create(
        uuid:  uuid,
        attrs: { message_inference_request_id: request, status: 'created' }
      )

      expect(second[:id]).to eq(first[:id])
      expect(db[:llm_message_inference_responses].where(uuid: uuid).count).to eq(1)
    end

    it 'merges supplied attrs into the created record' do
      uuid = 'find-or-create-resp-attrs-uuid'
      record = described_class.find_or_create(
        uuid:  uuid,
        attrs: { message_inference_request_id: request, status: 'success', provider: 'anthropic' }
      )
      expect(record[:provider]).to eq('anthropic')
    end
  end
end
