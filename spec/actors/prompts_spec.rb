# frozen_string_literal: true

RSpec.describe Legion::Extensions::Llm::Ledger::Actor::Prompts do
  subject(:actor) { described_class.new }

  it 'returns Runners::Prompts as runner_class' do
    expect(actor.runner_class).to eq(Legion::Extensions::Llm::Ledger::Runners::Prompts)
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

  it 'uses the AuditPrompts queue' do
    expect(actor.queue).to eq(Legion::Extensions::Llm::Ledger::Transport::Queues::AuditPrompts)
  end
end
