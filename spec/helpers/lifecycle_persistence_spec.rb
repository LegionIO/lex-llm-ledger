# frozen_string_literal: true

RSpec.describe Legion::Extensions::Llm::Ledger::Helpers::LifecyclePersistence do
  let(:prompt_body) do
    {
      conversation_id:     'conv-1',
      request_id:          'req-1',
      response_message_id: 'resp-msg-1',
      operation:           'chat',
      provider:            'ollama',
      provider_instance:   'local',
      model_id:            'qwen3.5:27b',
      tier:                'fleet',
      request:             { messages: [{ role: 'user', content: 'Hello' }] },
      response:            { message: { role: 'assistant', content: 'Hi' } },
      tokens:              { input: 10, output: 5, total: 15 },
      recorded_at:         '2026-04-08T14:30:01Z'
    }
  end

  let(:metering_body) do
    {
      conversation_id: 'conv-1',
      request_id:      'req-1',
      operation:       'chat',
      provider:        'ollama',
      model_id:        'qwen3.5:27b',
      tier:            'fleet',
      input_tokens:    10,
      output_tokens:   5,
      total_tokens:    15,
      recorded_at:     '2026-04-08T14:30:01Z'
    }
  end

  it 'writes prompt lifecycle rows and links the response message' do
    result = described_class.write_prompt(prompt_body)

    expect(result[:result]).to eq(:ok)
    expect(Legion::Data::Models::LLM::Message.count).to eq(2)
    expect(Legion::Data::Models::LLM::MessageInferenceRequest.count).to eq(1)
    expect(Legion::Data::Models::LLM::MessageInferenceResponse.count).to eq(1)

    response_message = Legion::Data::Models::LLM::Message.first(role: 'assistant')
    response = Legion::Data::Models::LLM::MessageInferenceResponse.first
    expect(response_message[:message_inference_response_id]).to eq(response[:id])
  end

  it 'writes metering rows without creating phantom messages' do
    result = described_class.write_metering(metering_body)

    expect(result[:result]).to eq(:ok)
    expect(Legion::Data::Models::LLM::Message.count).to eq(0)
    expect(Legion::Data::Models::LLM::MessageInferenceRequest.count).to eq(1)
    expect(Legion::Data::Models::LLM::MessageInferenceResponse.count).to eq(1)
    expect(Legion::Data::Models::LLM::MessageInferenceMetric.count).to eq(1)
  end
end
