# frozen_string_literal: true

RSpec.describe Legion::Extensions::Llm::Ledger::Runners::RouteAttempts do
  let(:db) { Legion::Data::Models::LLM::RouteAttempt.db }

  let(:conversation) do
    db[:llm_conversations].insert(
      uuid:             'route-spec-conv-uuid',
      retention_policy: 'default',
      inserted_at:      Time.now.utc,
      created_at:       Time.now.utc,
      updated_at:       Time.now.utc
    )
  end

  let(:request) do
    db[:llm_message_inference_requests].insert(
      uuid:            'route-spec-req-uuid',
      conversation_id: conversation,
      request_type:    'chat',
      status:          'created',
      inserted_at:     Time.now.utc
    )
  end

  let(:response) do
    db[:llm_message_inference_responses].insert(
      uuid:                         'route-spec-resp-uuid',
      message_inference_request_id: request,
      status:                       'created',
      inserted_at:                  Time.now.utc
    )
  end

  def insert_route_attempt(uuid:)
    db[:llm_route_attempts].insert(
      uuid:                         uuid,
      message_inference_request_id: request,
      attempt_no:                   1,
      status:                       'success',
      inserted_at:                  Time.now.utc
    )
  end

  describe '.fetch' do
    context 'by id' do
      it 'returns the route attempt record' do
        id = insert_route_attempt(uuid: 'fetch-route-by-id-uuid')
        record = described_class.fetch(id: id)
        expect(record).not_to be_nil
        expect(record[:uuid]).to eq('fetch-route-by-id-uuid')
      end

      it 'returns nil when id does not exist' do
        expect(described_class.fetch(id: 999_999)).to be_nil
      end
    end

    context 'by uuid' do
      it 'returns the route attempt record' do
        insert_route_attempt(uuid: 'fetch-route-by-uuid-target')
        record = described_class.fetch(uuid: 'fetch-route-by-uuid-target')
        expect(record).not_to be_nil
        expect(record[:uuid]).to eq('fetch-route-by-uuid-target')
      end

      it 'returns nil when uuid does not exist' do
        expect(described_class.fetch(uuid: 'no-such-route-uuid')).to be_nil
      end
    end

    context 'with no arguments' do
      it 'returns nil' do
        expect(described_class.fetch).to be_nil
      end
    end
  end

  describe '.insert' do
    it 'creates a new route attempt when uuid does not exist' do
      uuid = 'insert-route-new-uuid'
      record = described_class.insert(
        uuid:  uuid,
        attrs: {
          message_inference_request_id: request,
          attempt_no:                   1,
          status:                       'success'
        }
      )
      expect(record).not_to be_nil
      expect(record[:uuid]).to eq(uuid)
      expect(db[:llm_route_attempts].where(uuid: uuid).count).to eq(1)
    end

    it 'returns nil when the uuid already exists (dedup/append-only)' do
      uuid = 'insert-route-dedup-uuid'
      described_class.insert(
        uuid:  uuid,
        attrs: {
          message_inference_request_id: request,
          attempt_no:                   1,
          status:                       'success'
        }
      )
      result = described_class.insert(
        uuid:  uuid,
        attrs: {
          message_inference_request_id: request,
          attempt_no:                   1,
          status:                       'success'
        }
      )
      expect(result).to be_nil
      expect(db[:llm_route_attempts].where(uuid: uuid).count).to eq(1)
    end

    it 'merges supplied attrs into the created record' do
      uuid = 'insert-route-attrs-uuid'
      record = described_class.insert(
        uuid:  uuid,
        attrs: {
          message_inference_request_id: request,
          attempt_no:                   2,
          status:                       'failure',
          provider:                     'anthropic'
        }
      )
      expect(record[:provider]).to eq('anthropic')
      expect(record[:attempt_no]).to eq(2)
    end
  end
end
