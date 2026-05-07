# frozen_string_literal: true

RSpec.describe Legion::Extensions::Llm::Ledger::Actor::PromptWriter do
  subject(:actor) { described_class.new }

  it 'returns Runners::Prompts as runner_class' do
    expect(actor.runner_class).to eq(Legion::Extensions::Llm::Ledger::Runners::Prompts)
  end

  it 'returns write_prompt_record as runner_function' do
    expect(actor.runner_function).to eq('write_prompt_record')
  end

  it 'returns false for use_runner?' do
    expect(actor.use_runner?).to be false
  end

  it 'inherits from Subscription' do
    expect(described_class.superclass).to eq(Legion::Extensions::Actors::Subscription)
  end

  it 'uses the AuditPrompts queue' do
    expect(actor.queue).to eq(Legion::Extensions::Llm::Ledger::Transport::Queues::AuditPrompts)
  end

  it 'decodes clear JSON audit messages through the ledger decoder' do
    metadata = metadata(content_type: 'application/json', headers: { 'x-legion-identity' => 'user:matt' })

    message = actor.process_message(
      '{"message_context":{"conversation_id":"conv_123"},"request_id":"req_123"}',
      metadata,
      { routing_key: 'audit.prompt.chat' }
    )

    expect(message[:payload]).to include(request_id: 'req_123')
    expect(message[:payload][:message_context]).to include(conversation_id: 'conv_123')
    expect(message[:metadata][:headers]).to include('x-legion-identity' => 'user:matt')
    expect(message[:metadata][:properties]).to include(routing_key: 'audit.prompt.chat')
  end

  it 'decrypts encrypted audit messages through the ledger decoder' do
    stub_const('Legion::Crypt', crypt_module('{"message_context":{"conversation_id":"conv_456"}}'))
    stub_const('Legion::Crypt::DecryptionError', Class.new(StandardError))
    metadata = metadata(
      content_type:     'application/json',
      content_encoding: 'encrypted/cs',
      headers:          { 'iv' => 'base64iv==' }
    )

    message = actor.process_message('encrypted_blob', metadata, { routing_key: 'audit.prompt.chat' })

    expect(message[:payload][:message_context]).to include(conversation_id: 'conv_456')
  end

  it 'dead-letters encrypted audit messages missing iv before core decryption' do
    metadata = metadata(
      content_type:     'application/json',
      content_encoding: 'encrypted/cs',
      headers:          {}
    )

    expect do
      actor.process_message('encrypted_blob', metadata, { routing_key: 'audit.prompt.chat' })
    end.to raise_error(Legion::Extensions::Actors::UnrecoverableMessageError, /missing iv/)
  end

  def metadata(content_type:, headers:, content_encoding: nil)
    Struct.new(:headers, :content_type, :content_encoding, :message_id, :correlation_id, :app_id, :timestamp)
          .new(headers, content_type, content_encoding, 'msg_123', 'corr_123', 'lex-llm-ledger', Time.now)
  end

  def crypt_module(decrypted_payload)
    Module.new do
      define_singleton_method(:decrypt) { |_raw, _iv| decrypted_payload }
    end
  end
end
