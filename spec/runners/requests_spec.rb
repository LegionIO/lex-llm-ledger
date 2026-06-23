# frozen_string_literal: true

RSpec.describe Legion::Extensions::Llm::Ledger::Runners::Requests do
  let(:db) { Legion::Data::Models::LLM::MessageInferenceRequest.db }

  let(:conversation) do
    db[:llm_conversations].insert(
      uuid:             'req-spec-conv-uuid',
      retention_policy: 'default',
      inserted_at:      Time.now.utc,
      created_at:       Time.now.utc,
      updated_at:       Time.now.utc
    )
  end

  def insert_request(uuid:, request_ref: nil)
    attrs = {
      uuid:            uuid,
      conversation_id: conversation,
      request_type:    'chat',
      status:          'created',
      inserted_at:     Time.now.utc
    }
    attrs[:request_ref] = request_ref if request_ref
    db[:llm_message_inference_requests].insert(attrs)
  end

  def stable_uuid(value)
    raw = value.to_s
    return raw if raw.length <= 36

    hex = Digest::SHA256.hexdigest(raw)[0, 32]
    "#{hex[0, 8]}-#{hex[8, 4]}-#{hex[12, 4]}-#{hex[16, 4]}-#{hex[20, 12]}"
  end

  describe '.fetch' do
    context 'by id' do
      it 'returns the request record' do
        id = insert_request(uuid: 'fetch-req-by-id-uuid')
        record = described_class.fetch(id: id)
        expect(record).not_to be_nil
        expect(record[:uuid]).to eq('fetch-req-by-id-uuid')
      end

      it 'returns nil when id does not exist' do
        expect(described_class.fetch(id: 999_999)).to be_nil
      end
    end

    context 'by uuid' do
      it 'returns the request record' do
        insert_request(uuid: 'fetch-req-by-uuid-target')
        record = described_class.fetch(uuid: 'fetch-req-by-uuid-target')
        expect(record).not_to be_nil
        expect(record[:uuid]).to eq('fetch-req-by-uuid-target')
      end

      it 'returns nil when uuid does not exist' do
        expect(described_class.fetch(uuid: 'no-such-req-uuid')).to be_nil
      end
    end

    context 'by ref (request_ref column)' do
      it 'returns the request when request_ref matches directly' do
        insert_request(uuid: 'fetch-req-by-ref-uuid', request_ref: 'my-direct-ref')
        record = described_class.fetch(ref: 'my-direct-ref')
        expect(record).not_to be_nil
        expect(record[:request_ref]).to eq('my-direct-ref')
      end

      it 'falls back to stable_uuid lookup when ref is longer than 36 chars' do
        long_ref = 'req_this_is_a_reference_longer_than_36_chars'
        derived  = stable_uuid(long_ref)

        insert_request(uuid: derived)

        record = described_class.fetch(ref: long_ref)
        expect(record).not_to be_nil
        expect(record[:uuid]).to eq(derived)
      end

      it 'returns nil when no request matches the ref' do
        expect(described_class.fetch(ref: 'req_no_match_ref_that_does_not_exist')).to be_nil
      end
    end

    context 'with no arguments' do
      it 'returns nil' do
        expect(described_class.fetch).to be_nil
      end
    end
  end

  describe '.find_or_create' do
    it 'creates a new request when one does not exist' do
      uuid = 'find-or-create-req-new-uuid'
      record = described_class.find_or_create(
        uuid:  uuid,
        attrs: { conversation_id: conversation, request_type: 'chat', status: 'created' }
      )
      expect(record).not_to be_nil
      expect(record[:uuid]).to eq(uuid)
      expect(db[:llm_message_inference_requests].where(uuid: uuid).count).to eq(1)
    end

    it 'returns the existing request on second call (idempotent)' do
      uuid = 'find-or-create-req-idempotent-uuid'
      first = described_class.find_or_create(
        uuid:  uuid,
        attrs: { conversation_id: conversation, request_type: 'chat', status: 'created' }
      )
      second = described_class.find_or_create(
        uuid:  uuid,
        attrs: { conversation_id: conversation, request_type: 'chat', status: 'created' }
      )

      expect(second[:id]).to eq(first[:id])
      expect(db[:llm_message_inference_requests].where(uuid: uuid).count).to eq(1)
    end

    it 'merges supplied attrs into the created record' do
      uuid = 'find-or-create-req-attrs-uuid'
      record = described_class.find_or_create(
        uuid:  uuid,
        attrs: { conversation_id: conversation, request_type: 'chat', status: 'created', request_ref: 'my-ref-123' }
      )
      expect(record[:request_ref]).to eq('my-ref-123')
    end
  end
end
