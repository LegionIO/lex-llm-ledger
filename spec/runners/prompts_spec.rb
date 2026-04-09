# frozen_string_literal: true

RSpec.describe Legion::Extensions::LLM::Ledger::Runners::Prompts do
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
      routing:             { provider: 'ollama', model: 'qwen3.5:27b', tier: 'fleet' },
      tokens:              { input: 42, output: 28, total: 70 },
      cost:                { estimated_usd: 0.0 },
      caller:              { requested_by: { identity: 'user:matt', type: 'user' } },
      agent:               { id: 'gaia', task_id: 'task_abc' },
      classification:      { level: 'internal', contains_phi: false, contains_pii: false, jurisdictions: ['us'] },
      quality:             { score: 85, band: 'good' },
      timestamps:          { returned: '2026-04-08T14:30:01.247Z', provider_end: '2026-04-08T14:30:01.245Z' },
      request:             { system: 'You are a helpful assistant.', messages: [{ role: 'user', content: 'Hello' }] },
      response:            { message: { role: 'assistant', content: 'Hi there!' }, stop: { reason: 'end_turn' } }
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
    it 'inserts a record and returns ok' do
      result = described_class.write_prompt_record(decrypted_body, metadata)
      expect(result).to eq({ result: :ok })

      row = Legion::Data::DB[:prompt_records].first
      expect(row[:message_id]).to eq('audit_prompt_abc123')
      expect(row[:correlation_id]).to eq('req_abc')
      expect(row[:conversation_id]).to eq('conv_123')
      expect(row[:response_message_id]).to eq('msg_006')
      expect(row[:provider]).to eq('ollama')
      expect(row[:model_id]).to eq('qwen3.5:27b')
      expect(row[:tier]).to eq('fleet')
      expect(row[:request_type]).to eq('chat')
      expect(row[:input_tokens]).to eq(42)
      expect(row[:output_tokens]).to eq(28)
      expect(row[:total_tokens]).to eq(70)
      expect(row[:caller_identity]).to eq('user:matt')
      expect(row[:caller_type]).to eq('user')
      expect(row[:agent_id]).to eq('gaia')
      expect(row[:quality_score]).to eq(85)
      expect(row[:quality_band]).to eq('good')
      expect(row[:recorded_at]).to eq('2026-04-08T14:30:01.247Z')
    end

    it 'stores request_json and response_json as JSON strings' do
      described_class.write_prompt_record(decrypted_body, metadata)
      row = Legion::Data::DB[:prompt_records].first
      parsed_request = JSON.parse(row[:request_json])
      expect(parsed_request['system']).to eq('You are a helpful assistant.')
      parsed_response = JSON.parse(row[:response_json])
      expect(parsed_response['message']['content']).to eq('Hi there!')
    end

    it 'returns duplicate on second insert' do
      described_class.write_prompt_record(decrypted_body, metadata)
      result = described_class.write_prompt_record(decrypted_body, metadata)
      expect(result).to eq({ result: :duplicate })
    end

    it 'sets contains_phi true from header' do
      metadata[:headers]['x-legion-contains-phi'] = 'true'
      described_class.write_prompt_record(decrypted_body, metadata)
      row = Legion::Data::DB[:prompt_records].first
      expect(row[:contains_phi]).to be true
    end

    it 'applies PHI TTL cap when PHI flagged' do
      metadata[:headers]['x-legion-contains-phi'] = 'true'
      described_class.write_prompt_record(decrypted_body, metadata)
      row = Legion::Data::DB[:prompt_records].first
      expect(row[:expires_at]).not_to be_nil
    end

    it 'sets nil expires_at for permanent non-PHI' do
      metadata[:headers]['x-legion-retention'] = 'permanent'
      described_class.write_prompt_record(decrypted_body, metadata)
      row = Legion::Data::DB[:prompt_records].first
      expect(row[:expires_at]).to be_nil
    end

    it 'propagates DecryptionUnavailable (NACK for requeue)' do
      metadata[:properties][:content_encoding] = 'encrypted/cs'
      expect do
        described_class.write_prompt_record('encrypted_blob', metadata)
      end.to raise_error(Legion::Extensions::LLM::Ledger::Helpers::DecryptionUnavailable)
    end
  end
end
