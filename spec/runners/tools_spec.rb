# frozen_string_literal: true

RSpec.describe Legion::Extensions::Llm::Ledger::Runners::Tools do
  let(:db) { Legion::Data.connection }

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

  # Seed a conversation + request + response so the tool runner can link.
  def seed_inference_response(request_id: 'req_abc', conversation_id: 'conv_123')
    req_id = seed_inference_request(request_id: request_id, conversation_id: conversation_id)
    db[:llm_message_inference_responses].insert(
      uuid:                         Legion::Extensions::Llm::Ledger::Writers::OfficialRecordWriter.stable_uuid("response:#{request_id}"),
      message_inference_request_id: req_id,
      provider:                     'vllm',
      model_key:                    'qwen3.6-27b',
      status:                       'success',
      responded_at:                 Time.now.utc,
      inserted_at:                  Time.now.utc
    )
  end

  def seed_inference_request(request_id: 'req_abc', conversation_id: 'conv_123')
    conv_uuid = Legion::Extensions::Llm::Ledger::Writers::OfficialRecordWriter.stable_uuid(conversation_id)
    conv_id = db[:llm_conversations].insert(
      uuid:             conv_uuid,
      retention_policy: 'default',
      inserted_at:      Time.now.utc,
      created_at:       Time.now.utc,
      updated_at:       Time.now.utc
    )
    db[:llm_message_inference_requests].insert(
      uuid:            Legion::Extensions::Llm::Ledger::Writers::OfficialRecordWriter.stable_uuid(request_id),
      conversation_id: conv_id,
      request_ref:     request_id,
      status:          'responded',
      operation:       'chat',
      request_type:    'chat',
      requested_at:    Time.now.utc,
      inserted_at:     Time.now.utc
    )
  end

  describe '.write_tool_record' do
    context 'when a linked inference response exists' do
      before { seed_inference_response }

      it 'inserts a tool_call row and returns ok' do
        result = described_class.write_tool_record(decrypted_body, metadata)
        expect(result).to eq({ result: :ok })

        row = db[:llm_tool_calls].first
        expect(row).not_to be_nil
        expect(row[:tool_name]).to eq('list_files')
        expect(row[:tool_source_type]).to eq('mcp')
        expect(row[:tool_source_server]).to eq('filesystem')
        expect(row[:provider_tool_call_ref]).to eq('tc_def456')
        expect(row[:status]).to eq('success')
        expect(row[:requested_at].to_s).to include('2026-04-08')
        expect(row[:completed_at].to_s).to include('2026-04-08')
      end

      it 'inserts a tool_call_attempt row with duration and refs' do
        described_class.write_tool_record(decrypted_body, metadata)

        attempt = db[:llm_tool_call_attempts].first
        expect(attempt).not_to be_nil
        expect(attempt[:attempt_no]).to eq(1)
        expect(attempt[:status]).to eq('success')
        expect(attempt[:duration_ms]).to eq(45)
        expect(attempt[:arguments_ref]).to be_a(String)
        expect(attempt[:arguments_ref].length).to eq(64)
        expect(attempt[:result_ref]).to be_a(String)
      end

      it 'stores SHA-256 hashes of arguments and result in the attempt' do
        described_class.write_tool_record(decrypted_body, metadata)
        attempt = db[:llm_tool_call_attempts].first
        expected_args_ref = Digest::SHA256.hexdigest(
          Legion::Extensions::Llm::Ledger::Helpers::Json.dump({ path: '/src' })
        )[0, 64]
        expect(attempt[:arguments_ref]).to eq(expected_args_ref)
      end

      it 'links attempt to tool_call' do
        described_class.write_tool_record(decrypted_body, metadata)
        tool_call = db[:llm_tool_calls].first
        attempt   = db[:llm_tool_call_attempts].first
        expect(attempt[:tool_call_id]).to eq(tool_call[:id])
      end

      it 'accepts subscription keyword envelopes with payload and metadata' do
        result = described_class.write_tool_record(payload: decrypted_body, metadata: metadata)
        expect(result).to eq({ result: :ok })
        expect(db[:llm_tool_calls].count).to eq(1)
      end

      it 'is idempotent on second invocation (returns duplicate)' do
        described_class.write_tool_record(decrypted_body, metadata)
        result = described_class.write_tool_record(decrypted_body, metadata)
        expect(result).to eq({ result: :duplicate })
        expect(db[:llm_tool_calls].count).to eq(1)
      end

      it 'uses header fallback for tool_name when tool_call.name is absent' do
        decrypted_body[:tool_call].delete(:name)
        described_class.write_tool_record(decrypted_body, metadata)
        row = db[:llm_tool_calls].first
        expect(row[:tool_name]).to eq('list_files')
      end

      it 'writes identity_canonical_name on tool_call when caller identity is present' do
        body_with_identity = decrypted_body.merge(
          identity: { identity: 'miverso2', type: 'human', credential: 'entra_delegated' }
        )
        described_class.write_tool_record(body_with_identity, metadata)

        row = db[:llm_tool_calls].first
        expect(row[:identity_canonical_name]).to eq('miverso2')
      end

      it 'writes identity_canonical_name on tool_call_attempt when caller identity is present' do
        body_with_identity = decrypted_body.merge(
          identity: { identity: 'miverso2', type: 'human', credential: 'entra_delegated' }
        )
        described_class.write_tool_record(body_with_identity, metadata)

        attempt = db[:llm_tool_call_attempts].first
        expect(attempt[:identity_canonical_name]).to eq('miverso2')
      end

      it 'resolves identity_principal_id and identity_id when identity tables available' do
        body_with_identity = decrypted_body.merge(
          identity: { identity: 'miverso2', type: 'human', credential: 'entra_delegated' }
        )
        described_class.write_tool_record(body_with_identity, metadata)

        principal = db[:identity_principals].first
        identity  = db[:identities].first
        row       = db[:llm_tool_calls].first
        attempt   = db[:llm_tool_call_attempts].first

        expect(row[:identity_principal_id]).to eq(principal[:id])
        expect(row[:identity_id]).to eq(identity[:id])
        expect(attempt[:identity_principal_id]).to eq(principal[:id])
        expect(attempt[:identity_id]).to eq(identity[:id])
      end

      it 'writes nil identity columns when no caller identity present' do
        body_no_identity = decrypted_body.except(:caller).merge(identity: nil)
        described_class.write_tool_record(body_no_identity, metadata)

        row = db[:llm_tool_calls].first
        expect(row[:identity_canonical_name]).to be_nil
      end

      it 'does not write to the legacy llm_tool_records table' do
        described_class.write_tool_record(decrypted_body, metadata)
        expect(db.table_exists?(:llm_tool_records) ? db[:llm_tool_records].count : 0).to eq(0)
      end
    end

    context 'when no inference response exists for the request' do
      it 'raises UnrecoverableMessageError so the subscription rejects without requeue when parent rows are missing' do
        expect do
          described_class.write_tool_record(decrypted_body, metadata)
        end.to raise_error(Legion::Extensions::Actors::UnrecoverableMessageError, /no response row found/)

        expect(db[:llm_tool_calls].count).to eq(0)
      end

      it 'raises UnrecoverableMessageError when request exists before response commit' do
        seed_inference_request

        expect do
          described_class.write_tool_record(decrypted_body, metadata)
        end.to raise_error(Legion::Extensions::Actors::UnrecoverableMessageError, /no response row found/)

        expect(db[:llm_tool_calls].count).to eq(0)
      end
    end

    it 'propagates DecryptionFailed for missing iv headers (NACK without requeue)' do
      metadata[:properties][:content_encoding] = 'encrypted/cs'
      expect do
        described_class.write_tool_record('encrypted_blob', metadata)
      end.to raise_error(Legion::Extensions::Llm::Ledger::Helpers::DecryptionFailed, /missing iv/)
    end
  end
end
