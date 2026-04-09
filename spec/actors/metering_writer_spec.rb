# frozen_string_literal: true

RSpec.describe Legion::Extensions::Llm::Ledger::Actor::MeteringWriter do
  subject(:actor) { described_class.new }

  it 'returns Runners::Metering as runner_class' do
    expect(actor.runner_class).to eq(Legion::Extensions::Llm::Ledger::Runners::Metering)
  end

  it 'returns write_metering_record as runner_function' do
    expect(actor.runner_function).to eq('write_metering_record')
  end

  it 'returns false for use_runner?' do
    expect(actor.use_runner?).to be false
  end

  it 'inherits from Subscription' do
    expect(described_class.superclass).to eq(Legion::Extensions::Actors::Subscription)
  end
end
