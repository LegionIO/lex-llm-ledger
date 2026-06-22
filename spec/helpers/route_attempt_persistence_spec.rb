# frozen_string_literal: true

RSpec.describe Legion::Extensions::Llm::Ledger::Helpers::RouteAttemptPersistence do
  let(:db) { Legion::Data::Models::LLM::RouteAttempt.db }

  let(:conversation_id) do
    db[:llm_conversations].insert(
      uuid:             'conv-route',
      retention_policy: 'default',
      inserted_at:      Time.now.utc,
      created_at:       Time.now.utc,
      updated_at:       Time.now.utc
    )
  end

  let(:request_id) do
    db[:llm_message_inference_requests].insert(
      uuid:            'req-uuid',
      conversation_id: conversation_id,
      request_ref:     'req-1',
      request_type:    'chat',
      operation:       'chat',
      status:          'responded',
      inserted_at:     Time.now.utc
    )
  end

  let(:response_id) do
    db[:llm_message_inference_responses].insert(
      uuid:                         'resp-uuid',
      message_inference_request_id: request_id,
      status:                       'success',
      inserted_at:                  Time.now.utc
    )
  end

  let(:request) { Legion::Data::Models::LLM::MessageInferenceRequest[request_id] }
  let(:response) { Legion::Data::Models::LLM::MessageInferenceResponse[response_id] }

  it 'is a no-op when route attempts are absent' do
    described_class.write_route_attempts(request, response, {})

    expect(db[:llm_route_attempts].count).to eq(0)
  end

  it 'writes one route attempt row when details are present' do
    body = {
      route_attempt_details: [
        {
          attempt_no:    1,
          provider:      'bedrock',
          model:         'anthropic.claude-sonnet-4-6-v1:0',
          status:        'success',
          dispatch_path: 'cloud',
          latency_ms:    123
        }
      ]
    }

    described_class.write_route_attempts(request, response, body)

    row = db[:llm_route_attempts].first
    expect(row[:message_inference_request_id]).to eq(request_id)
    expect(row[:message_inference_response_id]).to eq(response_id)
    expect(row[:provider]).to eq('bedrock')
    expect(row[:model_key]).to eq('anthropic.claude-sonnet-4-6-v1:0')
    expect(row[:dispatch_path]).to eq('cloud')
  end
end
