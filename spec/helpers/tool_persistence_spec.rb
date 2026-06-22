# frozen_string_literal: true

RSpec.describe Legion::Extensions::Llm::Ledger::Helpers::ToolPersistence do
  let(:db) { Legion::Data::Models::LLM::ToolCall.db }

  def stable_uuid(value)
    Legion::Extensions::Llm::Ledger::Helpers::StableIdentifiers.stable_uuid(value)
  end

  def seed_request_with_response(request_ref: 'req-1', conversation_ref: 'conv-1')
    conversation_id = db[:llm_conversations].insert(
      uuid:             stable_uuid(conversation_ref),
      retention_policy: 'default',
      inserted_at:      Time.now.utc,
      created_at:       Time.now.utc,
      updated_at:       Time.now.utc
    )
    request_id = db[:llm_message_inference_requests].insert(
      uuid:            stable_uuid(request_ref),
      conversation_id: conversation_id,
      request_ref:     request_ref,
      request_type:    'chat',
      operation:       'chat',
      status:          'responded',
      inserted_at:     Time.now.utc
    )
    db[:llm_message_inference_responses].insert(
      uuid:                         stable_uuid("response:#{request_ref}"),
      message_inference_request_id: request_id,
      status:                       'success',
      inserted_at:                  Time.now.utc
    )
  end

  it 'resolves a response from request context' do
    seed_request_with_response

    response = described_class.find_or_resolve_response_with_retry(
      { request_id: 'req-1' },
      { request_id: 'req-1' },
      {},
      {}
    )

    expect(response).not_to be_nil
    expect(response[:message_inference_request_id]).not_to be_nil
  end

  it 'writes tool call and attempt rows' do
    seed_request_with_response
    response = Legion::Data::Models::LLM::MessageInferenceResponse.first(
      uuid: stable_uuid('response:req-1')
    )

    result = described_class.write_tool_record(
      { request_id: 'req-1', message_context: { conversation_id: 'conv-1' }, timestamps: {} },
      {},
      { request_id: 'req-1', conversation_id: 'conv-1' },
      {},
      { id: 'call-1', name: 'lookup', arguments: { q: 'pgvector' }, result: { ok: true }, status: 'success' },
      response
    )

    expect(result).to eq({ result: :ok })
    expect(db[:llm_tool_calls].count).to eq(1)
    expect(db[:llm_tool_call_attempts].count).to eq(1)
  end
end
