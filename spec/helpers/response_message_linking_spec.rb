# frozen_string_literal: true

RSpec.describe 'Response message linking' do
  it 'links the response message row to the response row via Prompts.link' do
    conversation = Legion::Data::Models::LLM::Conversation.create(
      uuid:             'conv-link',
      retention_policy: 'default',
      inserted_at:      Time.now.utc,
      created_at:       Time.now.utc,
      updated_at:       Time.now.utc
    )
    request = Legion::Data::Models::LLM::MessageInferenceRequest.create(
      uuid:            'req-link',
      conversation_id: conversation[:id],
      request_ref:     'req-link',
      request_type:    'chat',
      operation:       'chat',
      status:          'responded',
      inserted_at:     Time.now.utc
    )
    message = Legion::Data::Models::LLM::Message.create(
      uuid:            'msg-uuid',
      conversation_id: conversation[:id],
      seq:             1,
      role:            'assistant',
      content:         'hi',
      inserted_at:     Time.now.utc,
      created_at:      Time.now.utc
    )
    response = Legion::Data::Models::LLM::MessageInferenceResponse.create(
      uuid:                         'resp-uuid',
      message_inference_request_id: request[:id],
      status:                       'success',
      inserted_at:                  Time.now.utc
    )

    Legion::Extensions::Llm::Ledger::Runners::Prompts.link(
      response_message_id: message[:id],
      response_id:         response[:id]
    )

    expect(Legion::Data::Models::LLM::Message[message[:id]][:message_inference_response_id]).to eq(response[:id])
  end
end
