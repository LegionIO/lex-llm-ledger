# frozen_string_literal: true

RSpec.describe Legion::Extensions::Llm::Ledger::Helpers::ResponseMessageLinking do
  let(:db) { Legion::Data::Models::LLM::Message.db }

  it 'links the response message row to the response row' do
    conversation_id = db[:llm_conversations].insert(
      uuid:             'conv-link',
      retention_policy: 'default',
      inserted_at:      Time.now.utc,
      created_at:       Time.now.utc,
      updated_at:       Time.now.utc
    )
    request_id = db[:llm_message_inference_requests].insert(
      uuid:            'req-link',
      conversation_id: conversation_id,
      request_ref:     'req-link',
      request_type:    'chat',
      operation:       'chat',
      status:          'responded',
      inserted_at:     Time.now.utc
    )
    message_id = db[:llm_messages].insert(
      uuid:            'msg-uuid',
      conversation_id: conversation_id,
      seq:             1,
      role:            'assistant',
      content:         'hi',
      inserted_at:     Time.now.utc,
      created_at:      Time.now.utc
    )
    response_id = db[:llm_message_inference_responses].insert(
      uuid:                         'resp-uuid',
      message_inference_request_id: request_id,
      status:                       'success',
      inserted_at:                  Time.now.utc
    )

    described_class.response_message_linking_link_response_message!(
      Legion::Data::Models::LLM::Message[message_id],
      Legion::Data::Models::LLM::MessageInferenceResponse[response_id]
    )

    expect(Legion::Data::Models::LLM::Message[message_id][:message_inference_response_id]).to eq(response_id)
  end
end
