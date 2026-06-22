# frozen_string_literal: true

RSpec.describe Legion::Extensions::Llm::Ledger::Actor::Tools do
  subject(:actor) { described_class.new }

  it 'returns Runners::Tools as runner_class' do
    expect(actor.runner_class).to eq(Legion::Extensions::Llm::Ledger::Runners::Tools)
  end

  it 'returns insert as runner_function' do
    expect(actor.runner_function).to eq('insert')
  end

  it 'returns false for use_runner?' do
    expect(actor.use_runner?).to be false
  end

  it 'inherits from Subscription' do
    expect(described_class.superclass).to eq(Legion::Extensions::Actors::Subscription)
  end

  it 'uses the AuditTools queue' do
    expect(actor.queue).to eq(Legion::Extensions::Llm::Ledger::Transport::Queues::AuditTools)
  end
end
