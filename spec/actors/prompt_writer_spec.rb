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

  it 'decodes encrypted audit payloads with symbol iv headers' do
    crypt_mod = Module.new do
      def self.decrypt(message, init_vec)
        raise 'wrong message' unless message == 'gcm:cipher:tag'
        raise 'wrong iv' unless init_vec == 'base64iv=='

        '{"message_context":{"conversation_id":"conv_123"},"request":{"messages":[]}}'
      end
    end
    stub_const('Legion::Crypt', crypt_mod)

    metadata = Struct.new(:content_encoding, :content_type, :headers, :message_id, :correlation_id).new(
      'encrypted/cs',
      'application/json',
      { iv: 'base64iv==', 'x-legion-retention' => 'default' },
      'audit_prompt_123',
      'req_123'
    )
    delivery_info = { routing_key: 'audit.prompt.chat' }

    message = actor.process_message('gcm:cipher:tag', metadata, delivery_info)

    expect(message[:payload][:message_context][:conversation_id]).to eq('conv_123')
    expect(message[:metadata][:headers]['iv']).to eq('base64iv==')
    expect(message[:metadata][:properties][:message_id]).to eq('audit_prompt_123')
    expect(message[:metadata][:properties][:routing_key]).to eq('audit.prompt.chat')
  end

  it 'passes identity audit JSON without decrypting' do
    metadata = Struct.new(:content_encoding, :content_type, :headers, :message_id, :correlation_id).new(
      'identity',
      'application/json',
      { 'x-legion-retention' => 'default' },
      'audit_prompt_123',
      'req_123'
    )
    delivery_info = { routing_key: 'audit.prompt.chat' }
    payload = '{"message_context":{"conversation_id":"conv_123"},"request":{"messages":[]}}'

    message = actor.process_message(payload, metadata, delivery_info)

    expect(message[:payload][:message_context][:conversation_id]).to eq('conv_123')
    expect(message[:metadata][:headers]['x-legion-retention']).to eq('default')
    expect(message[:metadata][:properties][:content_encoding]).to eq('identity')
  end

  it 'raises a ledger decryption error when encrypted audit payloads omit iv headers' do
    metadata = Struct.new(:content_encoding, :content_type, :headers, :message_id, :correlation_id).new(
      'encrypted/cs',
      'application/json',
      {},
      'audit_prompt_123',
      'req_123'
    )

    expect do
      actor.process_message('gcm:cipher:tag', metadata, { routing_key: 'audit.prompt.chat' })
    end.to raise_error(
      Legion::Extensions::Llm::Ledger::Helpers::DecryptionFailed,
      'Encrypted audit record is missing iv header'
    )
  end
end
