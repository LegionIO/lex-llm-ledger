# frozen_string_literal: true

RSpec.describe Legion::Extensions::Llm::Ledger::Runners::ContextAccountingEvents do
  let(:db) { Legion::Data::Models::LLM::ContextAccountingEvent.db }

  let(:conversation) do
    db[:llm_conversations].insert(
      uuid:             'cae-spec-conv-uuid',
      retention_policy: 'default',
      inserted_at:      Time.now.utc,
      created_at:       Time.now.utc,
      updated_at:       Time.now.utc
    )
  end

  let(:request) do
    db[:llm_message_inference_requests].insert(
      uuid:            'cae-spec-req-uuid',
      conversation_id: conversation,
      request_type:    'chat',
      status:          'created',
      inserted_at:     Time.now.utc
    )
  end

  let(:response) do
    db[:llm_message_inference_responses].insert(
      uuid:                         'cae-spec-resp-uuid',
      message_inference_request_id: request,
      status:                       'created',
      inserted_at:                  Time.now.utc
    )
  end

  let(:metric) do
    db[:llm_message_inference_metrics].insert(
      uuid:                         'cae-spec-metric-uuid',
      message_inference_request_id: request,
      inserted_at:                  Time.now.utc
    )
  end

  def insert_cae(uuid:)
    db[:llm_context_accounting_events].insert(
      uuid:                         uuid,
      message_inference_request_id: request,
      request_ref:                  'cae-spec-req-ref',
      event_type:                   'curation',
      component:                    'history_manager',
      inserted_at:                  Time.now.utc
    )
  end

  describe '.fetch' do
    context 'by id' do
      it 'returns the context accounting event record' do
        id = insert_cae(uuid: 'fetch-cae-by-id-uuid')
        record = described_class.fetch(id: id)
        expect(record).not_to be_nil
        expect(record[:uuid]).to eq('fetch-cae-by-id-uuid')
      end

      it 'returns nil when id does not exist' do
        expect(described_class.fetch(id: 999_999)).to be_nil
      end
    end

    context 'by uuid' do
      it 'returns the context accounting event record' do
        insert_cae(uuid: 'fetch-cae-by-uuid-target')
        record = described_class.fetch(uuid: 'fetch-cae-by-uuid-target')
        expect(record).not_to be_nil
        expect(record[:uuid]).to eq('fetch-cae-by-uuid-target')
      end

      it 'returns nil when uuid does not exist' do
        expect(described_class.fetch(uuid: 'no-such-cae-uuid')).to be_nil
      end
    end

    context 'with no arguments' do
      it 'returns nil' do
        expect(described_class.fetch).to be_nil
      end
    end
  end

  describe '.insert' do
    it 'creates a new context accounting event when uuid does not exist' do
      uuid = 'insert-cae-new-uuid'
      record = described_class.insert(
        uuid:  uuid,
        attrs: {
          message_inference_request_id: request,
          request_ref:                  'cae-test-ref',
          event_type:                   'curation',
          component:                    'history_manager'
        }
      )
      expect(record).not_to be_nil
      expect(record[:uuid]).to eq(uuid)
      expect(db[:llm_context_accounting_events].where(uuid: uuid).count).to eq(1)
    end

    it 'returns nil when the uuid already exists (dedup/append-only)' do
      uuid = 'insert-cae-dedup-uuid'
      described_class.insert(
        uuid:  uuid,
        attrs: {
          message_inference_request_id: request,
          request_ref:                  'cae-dedup-ref',
          event_type:                   'curation',
          component:                    'history_manager'
        }
      )
      result = described_class.insert(
        uuid:  uuid,
        attrs: {
          message_inference_request_id: request,
          request_ref:                  'cae-dedup-ref',
          event_type:                   'curation',
          component:                    'history_manager'
        }
      )
      expect(result).to be_nil
      expect(db[:llm_context_accounting_events].where(uuid: uuid).count).to eq(1)
    end

    it 'merges supplied attrs into the created record' do
      uuid = 'insert-cae-attrs-uuid'
      record = described_class.insert(
        uuid:  uuid,
        attrs: {
          message_inference_request_id: request,
          request_ref:                  'cae-attrs-ref',
          event_type:                   'archival',
          component:                    'context_window',
          estimated_tokens_before:      1000,
          estimated_tokens_after:       800
        }
      )
      expect(record[:event_type]).to eq('archival')
      expect(record[:component]).to eq('context_window')
      expect(record[:estimated_tokens_before]).to eq(1000)
      expect(record[:estimated_tokens_after]).to eq(800)
    end
  end
end
