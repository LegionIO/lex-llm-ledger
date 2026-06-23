# frozen_string_literal: true

RSpec.describe Legion::Extensions::Llm::Ledger::Runners::Messages do
  let(:db) { Legion::Data::Models::LLM::Message.db }

  let(:conversation) do
    db[:llm_conversations].insert(
      uuid:             'msg-spec-conv-uuid',
      retention_policy: 'default',
      inserted_at:      Time.now.utc,
      created_at:       Time.now.utc,
      updated_at:       Time.now.utc
    )
  end

  def insert_message(uuid:, seq: nil)
    seq ||= db[:llm_messages].count + 1
    db[:llm_messages].insert(
      uuid:            uuid,
      conversation_id: conversation,
      seq:             seq,
      role:            'user',
      content_type:    'text',
      inserted_at:     Time.now.utc,
      created_at:      Time.now.utc
    )
  end

  describe '.fetch' do
    context 'by id' do
      it 'returns the message record' do
        id = insert_message(uuid: 'fetch-msg-by-id-uuid')
        record = described_class.fetch(id: id)
        expect(record).not_to be_nil
        expect(record[:uuid]).to eq('fetch-msg-by-id-uuid')
      end

      it 'returns nil when id does not exist' do
        expect(described_class.fetch(id: 999_999)).to be_nil
      end
    end

    context 'by uuid' do
      it 'returns the message record' do
        insert_message(uuid: 'fetch-msg-by-uuid-target')
        record = described_class.fetch(uuid: 'fetch-msg-by-uuid-target')
        expect(record).not_to be_nil
        expect(record[:uuid]).to eq('fetch-msg-by-uuid-target')
      end

      it 'returns nil when uuid does not exist' do
        expect(described_class.fetch(uuid: 'no-such-msg-uuid')).to be_nil
      end
    end

    context 'with no arguments' do
      it 'returns nil' do
        expect(described_class.fetch).to be_nil
      end
    end
  end

  describe '.find_or_create' do
    it 'creates a new message when one does not exist' do
      uuid = 'find-or-create-msg-new-uuid'
      record = described_class.find_or_create(
        uuid:  uuid,
        attrs: { conversation_id: conversation, seq: 1, role: 'user', content_type: 'text' }
      )
      expect(record).not_to be_nil
      expect(record[:uuid]).to eq(uuid)
      expect(db[:llm_messages].where(uuid: uuid).count).to eq(1)
    end

    it 'returns the existing message on second call (idempotent)' do
      uuid = 'find-or-create-msg-idempotent-uuid'
      first = described_class.find_or_create(
        uuid:  uuid,
        attrs: { conversation_id: conversation, seq: 2, role: 'user', content_type: 'text' }
      )
      second = described_class.find_or_create(
        uuid:  uuid,
        attrs: { conversation_id: conversation, seq: 2, role: 'user', content_type: 'text' }
      )

      expect(second[:id]).to eq(first[:id])
      expect(db[:llm_messages].where(uuid: uuid).count).to eq(1)
    end

    it 'merges supplied attrs into the created record' do
      uuid = 'find-or-create-msg-attrs-uuid'
      record = described_class.find_or_create(
        uuid:  uuid,
        attrs: { conversation_id: conversation, seq: 3, role: 'assistant', content_type: 'text' }
      )
      expect(record[:role]).to eq('assistant')
    end
  end
end
