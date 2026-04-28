# frozen_string_literal: true

RSpec.describe Legion::Extensions::Llm::Ledger::Transport do
  describe '.additional_e_to_q' do
    it 'binds the llm.registry exchange to the registry availability queue' do
      binding = described_class.additional_e_to_q.find do |entry|
        entry[:from] == Legion::Extensions::Llm::Ledger::Transport::Exchanges::Registry
      end

      expect(binding).to eq(
        {
          from:        Legion::Extensions::Llm::Ledger::Transport::Exchanges::Registry,
          to:          Legion::Extensions::Llm::Ledger::Transport::Queues::RegistryAvailability,
          routing_key: '#'
        }
      )
    end
  end
end
