# frozen_string_literal: true

RSpec.describe Legion::Extensions::Llm::Ledger::Runners::Conversations do
  let(:db) { Legion::Data::Models::LLM::Conversation.db }

  def insert_conversation(uuid:)
    db[:llm_conversations].insert(
      uuid:             uuid,
      retention_policy: 'default',
      inserted_at:      Time.now.utc,
      created_at:       Time.now.utc,
      updated_at:       Time.now.utc
    )
  end

  describe '.fetch' do
    context 'by id' do
      it 'returns the conversation record' do
        id = insert_conversation(uuid: 'fetch-by-id-uuid')
        record = described_class.fetch(id: id)
        expect(record).not_to be_nil
        expect(record[:uuid]).to eq('fetch-by-id-uuid')
      end

      it 'returns nil when id does not exist' do
        expect(described_class.fetch(id: 999_999)).to be_nil
      end
    end

    context 'by uuid' do
      it 'returns the conversation record' do
        insert_conversation(uuid: 'fetch-by-uuid-target')
        record = described_class.fetch(uuid: 'fetch-by-uuid-target')
        expect(record).not_to be_nil
        expect(record[:uuid]).to eq('fetch-by-uuid-target')
      end

      it 'returns nil when uuid does not exist' do
        expect(described_class.fetch(uuid: 'no-such-uuid')).to be_nil
      end
    end

    context 'by ref (longer than 36 chars — derives stable uuid)' do
      it 'finds the conversation via its derived stable uuid' do
        # Compute the stable_uuid the same way the runner does
        raw = 'conv_this_is_a_reference_longer_than_36_chars'
        hex = Digest::SHA256.hexdigest(raw)[0, 32]
        derived = "#{hex[0, 8]}-#{hex[8, 4]}-#{hex[12, 4]}-#{hex[16, 4]}-#{hex[20, 12]}"

        insert_conversation(uuid: derived)

        record = described_class.fetch(ref: raw)
        expect(record).not_to be_nil
        expect(record[:uuid]).to eq(derived)
      end

      it 'returns nil when no conversation matches the derived uuid' do
        expect(described_class.fetch(ref: 'conv_no_match_longer_than_36_chars_here')).to be_nil
      end
    end

    context 'with no arguments' do
      it 'returns nil' do
        expect(described_class.fetch).to be_nil
      end
    end
  end

  describe '.find_or_create' do
    it 'creates a new conversation when one does not exist' do
      uuid = 'find-or-create-new-uuid'
      record = described_class.find_or_create(uuid: uuid)
      expect(record).not_to be_nil
      expect(record[:uuid]).to eq(uuid)
      expect(db[:llm_conversations].where(uuid: uuid).count).to eq(1)
    end

    it 'returns the existing conversation on second call (idempotent)' do
      uuid = 'find-or-create-idempotent-uuid'
      first  = described_class.find_or_create(uuid: uuid)
      second = described_class.find_or_create(uuid: uuid)

      expect(second[:id]).to eq(first[:id])
      expect(db[:llm_conversations].where(uuid: uuid).count).to eq(1)
    end

    it 'merges supplied attrs into the created record' do
      uuid = 'find-or-create-attrs-uuid'
      record = described_class.find_or_create(uuid: uuid, attrs: { retention_policy: 'permanent' })
      expect(record[:retention_policy]).to eq('permanent')
    end
  end
end
