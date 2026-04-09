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
end
