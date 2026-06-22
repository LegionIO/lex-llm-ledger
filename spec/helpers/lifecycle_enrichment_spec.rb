# frozen_string_literal: true

RSpec.describe Legion::Extensions::Llm::Ledger::Helpers::LifecycleEnrichment do
  let(:db) { Legion::Data::Models::LLM::Conversation.db }

  describe '.token_count' do
    it 'supports token alias keys from body[:tokens]' do
      body = { tokens: { input: 4, output: 9, thinking: 2, total: 15 } }

      expect(described_class.token_count(body, :input_tokens)).to eq(4)
      expect(described_class.token_count(body, :output_tokens)).to eq(9)
      expect(described_class.token_count(body, :thinking_tokens)).to eq(2)
      expect(described_class.token_count(body, :total_tokens)).to eq(15)
    end
  end

  describe '.context_accounting' do
    it 'reads nested context accounting payloads' do
      body = {
        context_accounting: {
          status: 'estimated',
          events: [{ event_type: 'rag', component: 'apollo' }]
        }
      }

      expect(described_class.context_accounting(body)[:status]).to eq('estimated')
      expect(described_class.context_accounting(body)[:events].size).to eq(1)
    end
  end

  describe '.enrich_request!' do
    it 'fills missing fields without clobbering richer existing data' do
      conversation_id = db[:llm_conversations].insert(
        uuid:             'conv-enrich',
        retention_policy: 'default',
        inserted_at:      Time.now.utc,
        created_at:       Time.now.utc,
        updated_at:       Time.now.utc
      )
      request_id = db[:llm_message_inference_requests].insert(
        uuid:            'req-enrich',
        conversation_id: conversation_id,
        request_ref:     'req-enrich',
        request_type:    'chat',
        operation:       'chat',
        status:          'responded',
        request_json:    '{}',
        inserted_at:     Time.now.utc
      )
      existing = Legion::Data::Models::LLM::MessageInferenceRequest[request_id]

      described_class.enrich_request!(
        existing,
        { request: { messages: [{ role: 'user', content: 'hello' }] }, caller: { class: 'Executor' } },
        nil
      )

      updated = Legion::Data::Models::LLM::MessageInferenceRequest[request_id]
      expect(updated[:runtime_caller_class]).to eq('Executor')
      expect(updated[:request_json]).not_to eq('{}')
    end
  end
end
