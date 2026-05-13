# frozen_string_literal: true

RSpec.describe Legion::Extensions::Llm::Ledger::Writers::OfficialPromptWriter do
  let(:payload) do
    {
      request_id:          'req-1',
      conversation_id:     'conv-1',
      message_id:          'msg-1',
      response_message_id: 'msg-2',
      operation:           'chat',
      correlation_id:      'corr-1',
      provider:            'vllm',
      provider_instance:   'apollo',
      model_id:            'qwen3.6-27b',
      dispatch_path:       'fleet',
      request:             { messages: [{ role: 'user', content: 'Hello?' }] },
      response:            {
        content:  'Hello',
        thinking: 'hidden'
      },
      tokens:              {
        input_tokens:    10,
        output_tokens:   3,
        thinking_tokens: 2,
        total_tokens:    15
      },
      cost:                { estimated_usd: 0.02 },
      recorded_at:         '2026-05-06T14:00:00Z'
    }
  end
  let(:record_writer) { Legion::Extensions::Llm::Ledger::Writers::OfficialRecordWriter }

  it 'persists prompt audit events into the official LLM lifecycle schema' do
    result = described_class.write(payload)

    expect(result[:result]).to eq(:ok)
    expect(Legion::Data.connection[:llm_conversations].count).to eq(1)
    expect(Legion::Data.connection[:llm_messages].count).to eq(2)
    expect(Legion::Data.connection[:llm_message_inference_requests].count).to eq(1)
    expect(Legion::Data.connection[:llm_message_inference_responses].count).to eq(1)
    expect(Legion::Data.connection[:llm_message_inference_metrics].count).to eq(1)

    request = Legion::Data.connection[:llm_message_inference_requests].first
    expect(request[:operation]).to eq('chat')
    expect(request[:correlation_id]).to eq('corr-1')
    expect(request[:request_type]).to eq('chat')

    response = Legion::Data.connection[:llm_message_inference_responses].first
    expect(response[:provider]).to eq('vllm')
    expect(response[:provider_instance]).to eq('apollo')
    expect(response[:model_key]).to eq('qwen3.6-27b')
    expect(response[:dispatch_path]).to eq('fleet')
    expect(JSON.parse(response[:response_json])).to eq('content' => 'Hello')
    expect(JSON.parse(response[:response_thinking_json])).to eq('content' => 'hidden')

    assistant_message = Legion::Data.connection[:llm_messages].where(role: 'assistant').first
    expect(assistant_message[:message_inference_response_id]).to eq(response[:id])
  end

  it 'is idempotent for the same request and response references' do
    described_class.write(payload)
    result = described_class.write(payload)

    expect(result[:result]).to eq(:ok)
    expect(Legion::Data.connection[:llm_conversations].count).to eq(1)
    expect(Legion::Data.connection[:llm_messages].count).to eq(2)
    expect(Legion::Data.connection[:llm_message_inference_requests].count).to eq(1)
    expect(Legion::Data.connection[:llm_message_inference_responses].count).to eq(1)
  end

  it 'enriches metering-first records without duplicate messages or metrics' do
    metering_payload = payload.except(:message_id, :response_message_id, :request, :response, :tokens).merge(
      input_tokens:    10,
      output_tokens:   3,
      thinking_tokens: 2,
      total_tokens:    15
    )

    Legion::Extensions::Llm::Ledger::Writers::OfficialMeteringWriter.write(metering_payload)
    result = described_class.write(payload)

    expect(result[:result]).to eq(:ok)
    expect(Legion::Data.connection[:llm_conversations].count).to eq(1)
    expect(Legion::Data.connection[:llm_messages].count).to eq(2)
    expect(Legion::Data.connection[:llm_message_inference_requests].count).to eq(1)
    expect(Legion::Data.connection[:llm_message_inference_responses].count).to eq(1)
    expect(Legion::Data.connection[:llm_message_inference_metrics].count).to eq(1)

    request = Legion::Data.connection[:llm_message_inference_requests].first
    response = Legion::Data.connection[:llm_message_inference_responses].first
    user_message = Legion::Data.connection[:llm_messages].where(role: 'user').first
    assistant_message = Legion::Data.connection[:llm_messages].where(role: 'assistant').first
    metric = Legion::Data.connection[:llm_message_inference_metrics].first

    expect(request[:latest_message_id]).to eq(user_message[:id])
    expect(response[:response_message_id]).to eq(assistant_message[:id])
    expect(assistant_message[:parent_message_id]).to eq(user_message[:id])
    expect(assistant_message[:message_inference_response_id]).to eq(response[:id])
    expect(metric[:uuid]).to eq(record_writer.stable_uuid('metric:req-1'))
  end

  it 'uses one generated request reference across a write when no request ids are present' do
    generated_payload = payload.except(:request_id, :correlation_id, :message_id, :response_message_id)

    described_class.write(generated_payload)

    request = Legion::Data.connection[:llm_message_inference_requests].first
    expect(request[:request_ref]).not_to be_nil
    expect(request[:uuid]).to eq(
      Legion::Extensions::Llm::Ledger::Writers::OfficialRecordWriter.stable_uuid(request[:request_ref])
    )
    assistant_message = Legion::Data.connection[:llm_messages].where(role: 'assistant').first
    expect(assistant_message[:message_inference_request_id]).to eq(request[:id])
  end

  %i[
    llm_conversations
    llm_message_inference_requests
    llm_message_inference_responses
    llm_message_inference_metrics
  ].each do |table_name|
    it "recovers when #{table_name} is inserted by a concurrent ledger consumer" do
      simulate_insert_race(table_name)

      result = described_class.write(payload)

      expect(result[:result]).to eq(:ok)
      expect(Legion::Data.connection[table_name].count).to eq(1)
    end
  end

  it 'resolves canonical caller identity strings into portable identity foreign keys' do
    described_class.write(
      payload.merge(
        caller_identity: 'matt@example.com',
        identity:        { identity: 'matt@example.com', type: 'human', credential: 'system' }
      )
    )

    principal = Legion::Data.connection[:identity_principals].first
    identity = Legion::Data.connection[:identities].first
    request = Legion::Data.connection[:llm_message_inference_requests].first

    expect(principal).to include(canonical_name: 'matt@example.com', kind: 'human')
    expect(identity).to include(principal_id: principal[:id], provider_identity_key: 'matt@example.com')
    expect(request[:caller_principal_id]).to eq(principal[:id])
    expect(request[:caller_identity_id]).to eq(identity[:id])
    expect(request[:runtime_caller_type]).to eq('human')
  end

  def simulate_insert_race(table_name)
    raced = false
    allow(record_writer).to receive(:insert_with_savepoint).and_wrap_original do |original, db, table, attributes, operation:|
      if table == table_name && !raced
        raced = true
        db[table].insert(attributes)
        raise Sequel::UniqueConstraintViolation, "duplicate #{table}"
      end

      original.call(db, table, attributes, operation: operation)
    end
  end
end
