# frozen_string_literal: true

RSpec.describe Legion::Extensions::Llm::Ledger::Runners::Tools do
  let(:db) { Legion::Data::Models::LLM::ToolCall.db }

  let(:decrypted_body) do
    {
      message_context: {
        conversation_id:   'conv_123',
        message_id:        'msg_005',
        parent_message_id: 'msg_004',
        message_seq:       5,
        request_id:        'req_abc',
        exchange_id:       'exch_004'
      },
      tool_call:       {
        id:          'tc_def456',
        name:        'list_files',
        arguments:   { path: '/src' },
        source:      { type: 'mcp', server: 'filesystem' },
        status:      'success',
        duration_ms: 45,
        result:      "main.rb\nconfig.rb",
        error:       nil
      },
      caller:          { requested_by: { identity: 'user:matt', type: 'user' } },
      agent:           { id: 'gaia' },
      classification:  { level: 'internal', contains_phi: false },
      timestamps:      { tool_start: '2026-04-08T14:30:01.260Z', tool_end: '2026-04-08T14:30:01.305Z' }
    }
  end

  let(:metadata) do
    {
      properties: {
        message_id:       'audit_tool_abc123',
        correlation_id:   'req_abc',
        content_encoding: 'identity'
      },
      headers:    {
        'x-legion-retention'          => 'default',
        'x-legion-contains-phi'       => 'false',
        'x-legion-tool-name'          => 'list_files',
        'x-legion-tool-source-type'   => 'mcp',
        'x-legion-tool-source-server' => 'filesystem',
        'x-legion-tool-status'        => 'success',
        'x-legion-classification'     => 'internal'
      }
    }
  end

  def stable_uuid(value)
    Legion::Extensions::Llm::Ledger::Helpers::StableIdentifiers.stable_uuid(value)
  end

  def seed_inference_response(request_id: 'req_abc', conversation_id: 'conv_123')
    request_id_value = seed_inference_request(request_id: request_id, conversation_id: conversation_id)

    db[:llm_message_inference_responses].insert(
      uuid:                         stable_uuid("response:#{request_id}"),
      message_inference_request_id: request_id_value,
      provider:                     'vllm',
      model_key:                    'qwen3.6-27b',
      status:                       'success',
      responded_at:                 Time.now.utc,
      inserted_at:                  Time.now.utc
    )
  end

  def seed_inference_request(request_id: 'req_abc', conversation_id: 'conv_123')
    conversation_uuid = stable_uuid(conversation_id)
    conversation_id_value = db[:llm_conversations].insert(
      uuid:             conversation_uuid,
      retention_policy: 'default',
      inserted_at:      Time.now.utc,
      created_at:       Time.now.utc,
      updated_at:       Time.now.utc
    )

    db[:llm_message_inference_requests].insert(
      uuid:            stable_uuid(request_id),
      conversation_id: conversation_id_value,
      request_ref:     request_id,
      status:          'responded',
      operation:       'chat',
      request_type:    'chat',
      requested_at:    Time.now.utc,
      inserted_at:     Time.now.utc
    )
  end

  describe '.insert' do
    context 'when a linked inference response exists' do
      before { seed_inference_response }

      it 'inserts a tool_call row and returns ok' do
        result = described_class.insert(payload: decrypted_body, metadata: metadata)

        expect(result).to eq({ result: :ok })

        row = db[:llm_tool_calls].first
        expect(row).not_to be_nil
        expect(row[:tool_name]).to eq('list_files')
        expect(row[:tool_source_type]).to eq('mcp')
        expect(row[:tool_source_server]).to eq('filesystem')
        expect(row[:provider_tool_call_ref]).to eq('tc_def456')
        expect(row[:status]).to eq('success')
      end

      it 'inserts a tool_call_attempt row with duration and refs' do
        described_class.insert(payload: decrypted_body, metadata: metadata)

        attempt = db[:llm_tool_call_attempts].first
        expect(attempt).not_to be_nil
        expect(attempt[:attempt_no]).to eq(1)
        expect(attempt[:status]).to eq('success')
        expect(attempt[:duration_ms]).to eq(45)
        expect(attempt[:arguments_ref].length).to eq(64)
        expect(attempt[:result_ref].length).to eq(64)
      end

      it 'is idempotent on second invocation' do
        described_class.insert(payload: decrypted_body, metadata: metadata)
        result = described_class.insert(payload: decrypted_body, metadata: metadata)

        expect(result).to eq({ result: :duplicate })
        expect(db[:llm_tool_calls].count).to eq(1)
      end

      it 'writes identity attributes when caller identity is present' do
        body_with_identity = decrypted_body.merge(
          identity: { identity: 'miverso2', type: 'human', credential: 'entra_delegated' }
        )

        described_class.insert(payload: body_with_identity, metadata: metadata)

        tool_call = db[:llm_tool_calls].first
        attempt = db[:llm_tool_call_attempts].first

        expect(tool_call[:identity_canonical_name]).to eq('miverso2')
        expect(attempt[:identity_canonical_name]).to eq('miverso2')
      end

      it 'accepts kwargs entrypoints' do
        result = described_class.insert(payload: decrypted_body, metadata: metadata, ignored: 'ok')

        expect(result).to eq({ result: :ok })
        expect(db[:llm_tool_calls].count).to eq(1)
      end
    end

    context 'when no inference response exists for the request' do
      it 'inserts the tool call with null response_id when parent rows are missing' do
        result = described_class.insert(payload: decrypted_body, metadata: metadata)

        expect(result).to eq({ result: :ok })
        expect(db[:llm_tool_calls].count).to eq(1)
        expect(db[:llm_tool_calls].first[:message_inference_response_id]).to be_nil
      end
    end

    it 'raises on non-terminal persistence failure so the delivery can retry' do
      seed_inference_response
      allow(Legion::Extensions::Llm::Ledger::Helpers::ToolPersistence).to receive(:write_tool_record)
        .and_raise(Sequel::DatabaseError, 'database down')

      expect do
        described_class.insert(payload: decrypted_body, metadata: metadata)
      end.to raise_error(Sequel::DatabaseError, /database down/)
    end

    it 'propagates DecryptionFailed for missing iv headers' do
      metadata[:properties][:content_encoding] = 'encrypted/cs'

      expect do
        described_class.insert(payload: 'encrypted_blob', metadata: metadata)
      end.to raise_error(Legion::Extensions::Llm::Ledger::Helpers::DecryptionFailed, /missing iv/)
    end
  end
end
