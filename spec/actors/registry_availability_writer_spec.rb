# frozen_string_literal: true

RSpec.describe Legion::Extensions::Llm::Ledger::Actor::RegistryAvailabilityWriter do
  subject(:actor) { described_class.new }

  it 'returns Runners::RegistryAvailability as runner_class' do
    expect(actor.runner_class).to eq(Legion::Extensions::Llm::Ledger::Runners::RegistryAvailability)
  end

  it 'returns write_registry_availability_record as runner_function' do
    expect(actor.runner_function).to eq('write_registry_availability_record')
  end

  it 'returns false for use_runner?' do
    expect(actor.use_runner?).to be false
  end

  it 'inherits from Subscription' do
    expect(described_class.superclass).to eq(Legion::Extensions::Actors::Subscription)
  end

  it 'decodes provider-neutral registry event JSON' do
    metadata = Struct.new(:content_encoding, :content_type, :headers, :message_id, :correlation_id).new(
      'identity',
      'application/json',
      {},
      'registry_event_123',
      'evt-123'
    )
    delivery_info = { routing_key: 'offering.available' }
    payload = '{"event_id":"evt-123","event_type":"offering_available","occurred_at":"2026-04-28T14:30:15Z"}'

    message = actor.process_message(payload, metadata, delivery_info)

    expect(message[:payload][:event_id]).to eq('evt-123')
    expect(message[:payload][:event_type]).to eq('offering_available')
    expect(message[:metadata][:properties][:message_id]).to eq('registry_event_123')
    expect(message[:metadata][:properties][:routing_key]).to eq('offering.available')
  end
end
