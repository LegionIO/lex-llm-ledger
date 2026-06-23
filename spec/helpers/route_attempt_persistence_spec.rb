# frozen_string_literal: true

RSpec.describe Legion::Extensions::Llm::Ledger::Helpers::RouteAttemptPersistence do
  let(:conversation) do
    Legion::Data::Models::LLM::Conversation.create(
      uuid:             'conv-route',
      retention_policy: 'default',
      inserted_at:      Time.now.utc,
      created_at:       Time.now.utc,
      updated_at:       Time.now.utc
    )
  end

  let(:request) do
    Legion::Data::Models::LLM::MessageInferenceRequest.create(
      uuid:            'req-uuid',
      conversation_id: conversation[:id],
      request_ref:     'req-1',
      request_type:    'chat',
      operation:       'chat',
      status:          'responded',
      inserted_at:     Time.now.utc
    )
  end

  let(:response) do
    Legion::Data::Models::LLM::MessageInferenceResponse.create(
      uuid:                         'resp-uuid',
      message_inference_request_id: request[:id],
      status:                       'success',
      inserted_at:                  Time.now.utc
    )
  end

  it 'is a no-op when route attempts are absent' do
    described_class.write_route_attempts(request, response, {})

    expect(Legion::Data::Models::LLM::RouteAttempt.count).to eq(0)
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

    row = Legion::Data::Models::LLM::RouteAttempt.first
    expect(row[:message_inference_request_id]).to eq(request[:id])
    expect(row[:message_inference_response_id]).to eq(response[:id])
    expect(row[:provider]).to eq('bedrock')
    expect(row[:model_key]).to eq('anthropic.claude-sonnet-4-6-v1:0')
    expect(row[:dispatch_path]).to eq('cloud')
  end
end
