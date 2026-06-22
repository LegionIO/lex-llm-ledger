# frozen_string_literal: true

RSpec.describe Legion::Extensions::Llm::Ledger::Backfill::LegacyLlmRecords do
  it 'backfills legacy LLM ledger rows into official schema tables' do
    insert_legacy_prompt
    insert_legacy_metering
    insert_legacy_tool
    insert_legacy_registry

    result = described_class.run

    expect(result[:z_archive_llm_prompt_records]).to eq(1)
    expect(result[:z_archive_llm_metering_records]).to eq(1)
    expect(result[:z_archive_llm_tool_records]).to eq(1)
    expect(result[:llm_registry_availability_records]).to eq(1)
    expect(Legion::Data.connection[:llm_message_inference_requests].count).to eq(2)
    expect(Legion::Data.connection[:llm_message_inference_metrics].count).to eq(2)
    expect(Legion::Data.connection[:llm_tool_calls].count).to eq(1)
    expect(Legion::Data.connection[:llm_registry_events].count).to eq(1)

    rerun_result = described_class.run
    expect(rerun_result).to eq(
      z_archive_llm_prompt_records:      0,
      z_archive_llm_metering_records:    0,
      z_archive_llm_tool_records:        0,
      llm_registry_availability_records: 0
    )
  end

  it 'skips legacy tool rows that cannot link to an existing official inference response' do
    insert_legacy_tool(request_id: 'missing-request')

    result = described_class.run

    expect(result[:z_archive_llm_tool_records]).to eq(0)
    expect(Legion::Data.connection[:llm_message_inference_requests].count).to eq(0)
    expect(Legion::Data.connection[:llm_message_inference_metrics].count).to eq(0)
    expect(Legion::Data.connection[:llm_tool_calls].count).to eq(0)
  end

  it 'hard-stops legacy-only writer mode after official cutover' do
    expect do
      described_class.ensure_no_legacy_writer_mode!(:legacy_only)
    end.to raise_error(ArgumentError, /Legacy LLM writer mode is disabled/)
  end

  # PRESERVATION CONTRACT — verify backfill UUID derivation is stable.
  describe 'preservation contract' do
    context 'backfill stability' do
      it 'does not re-process archived legacy rows on rerun' do
        insert_legacy_prompt
        insert_legacy_metering

        described_class.run
        rerun = described_class.run

        expect(rerun[:z_archive_llm_prompt_records]).to eq(0)
        expect(rerun[:z_archive_llm_metering_records]).to eq(0)
      end
    end
  end

  def insert_legacy_prompt
    Legion::Data.connection[:z_archive_llm_prompt_records].insert(
      message_id:             'audit-1',
      correlation_id:         'corr-1',
      conversation_id:        'conv-legacy',
      message_id_ctx:         'msg-1',
      request_id:             'req-prompt',
      response_message_id:    'msg-2',
      provider:               'vllm',
      model_id:               'qwen3.6-27b',
      tier:                   'fleet',
      request_type:           'chat',
      request_json:           '{"messages":[{"role":"user","content":"Hello?"}]}',
      response_json:          '{"content":"Hello"}',
      response_thinking_json: '{"content":"hidden"}',
      input_tokens:           10,
      output_tokens:          3,
      total_tokens:           13,
      recorded_at:            '2026-05-06T14:00:00Z'
    )
  end

  def insert_legacy_metering
    Legion::Data.connection[:z_archive_llm_metering_records].insert(
      message_id:      'meter-1',
      correlation_id:  'corr-2',
      conversation_id: 'conv-legacy',
      message_id_ctx:  'msg-3',
      request_id:      'req-meter',
      request_type:    'embed',
      tier:            'local',
      provider:        'ollama',
      model_id:        'mxbai-embed-large:latest',
      node_id:         'node-a',
      input_tokens:    5,
      output_tokens:   0,
      thinking_tokens: 0,
      total_tokens:    5,
      latency_ms:      40,
      wall_clock_ms:   41,
      cost_usd:        0.0,
      recorded_at:     '2026-05-06T14:00:01Z'
    )
  end

  def insert_legacy_tool(request_id: 'req-prompt')
    Legion::Data.connection[:z_archive_llm_tool_records].insert(
      message_id:      'tool-1',
      correlation_id:  'corr-3',
      conversation_id: 'conv-legacy',
      message_id_ctx:  'msg-4',
      request_id:      request_id,
      tool_call_id:    'call-1',
      tool_name:       'lookup',
      tool_status:     'success',
      arguments_json:  '{}',
      result_json:     '{"ok":true}',
      tool_start_at:   '2026-05-06T14:00:02Z',
      tool_end_at:     '2026-05-06T14:00:03Z'
    )
  end

  def insert_legacy_registry
    Legion::Data.connection[:llm_registry_availability_records].insert(
      event_id:          'registry-1',
      event_type:        'available',
      occurred_at:       '2026-05-06T14:00:04Z',
      provider_family:   'vllm',
      provider_instance: 'apollo',
      model_id:          'qwen3.6-27b',
      offering_json:     '{}',
      runtime_json:      '{}',
      capacity_json:     '{}',
      health_json:       '{"status":"ready"}',
      lane_json:         '{}',
      metadata_json:     '{}'
    )
  end
end
