# frozen_string_literal: true

RSpec.describe Legion::Extensions::Llm::Ledger::Runners::Prompts do
  let(:decrypted_body) do
    {
      message_context:     {
        conversation_id:   'conv_123',
        message_id:        'msg_005',
        parent_message_id: 'msg_004',
        message_seq:       5,
        request_id:        'req_abc',
        exchange_id:       'exch_005'
      },
      response_message_id: 'msg_006',
      routing:             { provider: 'ollama', model: 'qwen3.5:27b', tier: 'fleet', instance: 'local' },
      tokens:              { input: 42, output: 28, total: 70 },
      cost:                { estimated_usd: 0.0 },
      caller:              { requested_by: { identity: 'user:matt', type: 'user' } },
      agent:               { id: 'gaia', task_id: 'task_abc' },
      classification:      { level: 'internal', contains_phi: false, contains_pii: false, jurisdictions: ['us'] },
      quality:             { score: 85, band: 'good' },
      timestamps:          { returned: '2026-04-08T14:30:01.247Z', provider_end: '2026-04-08T14:30:01.245Z' },
      request:             { system: 'You are a helpful assistant.', messages: [{ role: 'user', content: 'Hello' }] },
      response:            { message: { role: 'assistant', content: 'Hi there!' }, stop: { reason: 'end_turn' } },
      response_thinking:   { content: 'internal chain', enabled: true, config: { budget_tokens: 128 } }
    }
  end

  let(:metadata) do
    {
      properties: {
        message_id:       'audit_prompt_abc123',
        correlation_id:   'req_abc',
        content_encoding: 'identity'
      },
      headers:    {
        'x-legion-retention'        => 'default',
        'x-legion-contains-phi'     => 'false',
        'x-legion-classification'   => 'internal',
        'x-legion-llm-request-type' => 'chat'
      }
    }
  end

  describe '.write_prompt_record' do
    it 'inserts official lifecycle rows and returns ok' do
      result = described_class.write_prompt_record(decrypted_body, metadata)
      expect(result).to include(result: :ok)

      conversation = Legion::Data.connection[:llm_conversations].first
      request = Legion::Data.connection[:llm_message_inference_requests].first
      response = Legion::Data.connection[:llm_message_inference_responses].first
      metric = Legion::Data.connection[:llm_message_inference_metrics].first

      expect(conversation[:uuid]).to eq('conv_123')
      expect(request[:request_ref]).to eq('req_abc')
      expect(request[:correlation_id]).to eq('req_abc')
      expect(request[:operation]).to eq('chat')
      expect(response[:provider]).to eq('ollama')
      expect(response[:provider_instance]).to eq('local')
      expect(response[:model_key]).to eq('qwen3.5:27b')
      expect(response[:dispatch_path]).to eq('fleet')
      expect(metric[:input_tokens]).to eq(42)
      expect(metric[:output_tokens]).to eq(28)
      expect(metric[:total_tokens]).to eq(70)
    end

    it 'stores request, visible response, and thinking as structured JSON' do
      described_class.write_prompt_record(decrypted_body, metadata)
      request = Legion::Data.connection[:llm_message_inference_requests].first
      response = Legion::Data.connection[:llm_message_inference_responses].first

      parsed_request = JSON.parse(request[:request_json])
      expect(parsed_request['system']).to eq('You are a helpful assistant.')
      parsed_response = JSON.parse(response[:response_json])
      expect(parsed_response['message']['content']).to eq('Hi there!')
      parsed_thinking = JSON.parse(response[:response_thinking_json])
      expect(parsed_thinking['content']).to eq('internal chain')
      expect(parsed_thinking['config']['budget_tokens']).to eq(128)
    end

    it 'accepts subscription keyword envelopes with payload and metadata' do
      result = described_class.write_prompt_record(payload: decrypted_body, metadata: metadata)

      expect(result).to include(result: :ok)
      request = Legion::Data.connection[:llm_message_inference_requests].first
      expect(request[:request_ref]).to eq('req_abc')
      expect(request[:correlation_id]).to eq('req_abc')
    end

    it 'is idempotent on second insert' do
      described_class.write_prompt_record(decrypted_body, metadata)
      result = described_class.write_prompt_record(decrypted_body, metadata)

      expect(result).to include(result: :ok)
      expect(Legion::Data.connection[:llm_message_inference_requests].count).to eq(1)
      expect(Legion::Data.connection[:llm_message_inference_responses].count).to eq(1)
      expect(Legion::Data.connection[:llm_message_inference_metrics].count).to eq(1)
    end

    it 'sets contains_phi true from header' do
      metadata[:headers]['x-legion-contains-phi'] = 'true'
      described_class.write_prompt_record(decrypted_body, metadata)
      row = Legion::Data.connection[:llm_conversations].first
      expect(row[:contains_phi]).to be true
    end

    it 'applies PHI TTL cap when PHI flagged' do
      metadata[:headers]['x-legion-contains-phi'] = 'true'
      described_class.write_prompt_record(decrypted_body, metadata)
      row = Legion::Data.connection[:llm_conversations].first
      expect(row[:expires_at]).not_to be_nil
    end

    it 'sets nil expires_at for permanent non-PHI' do
      metadata[:headers]['x-legion-retention'] = 'permanent'
      described_class.write_prompt_record(decrypted_body, metadata)
      row = Legion::Data.connection[:llm_conversations].first
      expect(row[:expires_at]).to be_nil
    end

    it 'prefers current transport publisher identity over stale caller ids' do
      decrypted_body[:caller] = {
        requested_by: {
          id:       'system:system',
          identity: 'system',
          type:     'service'
        }
      }
      decrypted_body[:identity] = { identity: 'matt@example.com', type: 'human' }
      metadata[:headers]['x-legion-identity'] = 'matt@example.com'
      metadata[:headers]['x-legion-caller-type'] = 'human'

      official_payload = described_class.send(
        :official_context_payload,
        decrypted_body,
        decrypted_body[:message_context],
        metadata[:properties],
        metadata[:headers]
      ).merge(described_class.send(:official_identity_payload, decrypted_body, metadata[:headers]))

      expect(official_payload[:caller_identity]).to eq('matt@example.com')
      expect(official_payload[:caller_type]).to eq('human')
    end

    it 'propagates DecryptionFailed for missing iv headers (NACK without requeue)' do
      metadata[:properties][:content_encoding] = 'encrypted/cs'
      expect do
        described_class.write_prompt_record('encrypted_blob', metadata)
      end.to raise_error(Legion::Extensions::Llm::Ledger::Helpers::DecryptionFailed, /missing iv/)
    end
  end
end
