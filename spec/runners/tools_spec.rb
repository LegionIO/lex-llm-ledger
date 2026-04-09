# frozen_string_literal: true

RSpec.describe Legion::Extensions::Llm::Ledger::Runners::Tools do
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

  describe '.write_tool_record' do
    it 'inserts a record and returns ok' do
      result = described_class.write_tool_record(decrypted_body, metadata)
      expect(result).to eq({ result: :ok })

      row = Legion::Data::DB[:tool_records].first
      expect(row[:message_id]).to eq('audit_tool_abc123')
      expect(row[:correlation_id]).to eq('req_abc')
      expect(row[:conversation_id]).to eq('conv_123')
      expect(row[:tool_call_id]).to eq('tc_def456')
      expect(row[:tool_name]).to eq('list_files')
      expect(row[:tool_source_type]).to eq('mcp')
      expect(row[:tool_source_server]).to eq('filesystem')
      expect(row[:tool_status]).to eq('success')
      expect(row[:tool_duration_ms]).to eq(45)
      expect(row[:caller_identity]).to eq('user:matt')
      expect(row[:agent_id]).to eq('gaia')
      expect(row[:tool_start_at]).to eq('2026-04-08T14:30:01.260Z')
      expect(row[:tool_end_at]).to eq('2026-04-08T14:30:01.305Z')
    end

    it 'serializes arguments and result as JSON' do
      described_class.write_tool_record(decrypted_body, metadata)
      row = Legion::Data::DB[:tool_records].first
      parsed_args = JSON.parse(row[:arguments_json])
      expect(parsed_args['path']).to eq('/src')
      expect(row[:result_json]).to include('main.rb')
    end

    it 'stores null error_json when no error' do
      described_class.write_tool_record(decrypted_body, metadata)
      row = Legion::Data::DB[:tool_records].first
      expect(row[:error_json]).to eq('null')
    end

    it 'returns duplicate on second insert' do
      described_class.write_tool_record(decrypted_body, metadata)
      result = described_class.write_tool_record(decrypted_body, metadata)
      expect(result).to eq({ result: :duplicate })
    end

    it 'uses header fallback when tool_call.name is absent' do
      decrypted_body[:tool_call].delete(:name)
      described_class.write_tool_record(decrypted_body, metadata)
      row = Legion::Data::DB[:tool_records].first
      expect(row[:tool_name]).to eq('list_files')
    end

    it 'applies PHI TTL cap' do
      metadata[:headers]['x-legion-contains-phi'] = 'true'
      described_class.write_tool_record(decrypted_body, metadata)
      row = Legion::Data::DB[:tool_records].first
      expect(row[:contains_phi]).to be true
      expect(row[:expires_at]).not_to be_nil
    end

    it 'propagates DecryptionUnavailable (NACK for requeue)' do
      metadata[:properties][:content_encoding] = 'encrypted/cs'
      expect do
        described_class.write_tool_record('encrypted_blob', metadata)
      end.to raise_error(Legion::Extensions::Llm::Ledger::Helpers::DecryptionUnavailable)
    end
  end
end
