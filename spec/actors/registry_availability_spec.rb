# frozen_string_literal: true

RSpec.describe Legion::Extensions::Llm::Ledger::Actor::RegistryAvailability do
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

  it 'uses the RegistryAvailability queue' do
    expect(actor.queue).to eq(Legion::Extensions::Llm::Ledger::Transport::Queues::RegistryAvailability)
  end
end
