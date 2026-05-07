# frozen_string_literal: true

require 'legion/extensions/llm/ledger'

RSpec.describe Legion::Extensions::Llm::Ledger do
  describe '.default_settings' do
    it 'disables generated remote-invocation meta actors by default' do
      expect(described_class.default_settings).to include(remote_invocable: false)
    end
  end

  describe '.remote_invocable?' do
    around do |example|
      original = Legion::Settings[:extensions][:llm]&.delete(:ledger)
      example.run
    ensure
      Legion::Settings[:extensions][:llm] ||= {}
      Legion::Settings[:extensions][:llm][:ledger] = original if original
    end

    it 'returns false unless explicitly enabled' do
      Legion::Settings[:extensions][:llm] ||= {}
      Legion::Settings[:extensions][:llm][:ledger] = {}

      expect(described_class.remote_invocable?).to be false
    end

    it 'allows explicit opt-in for generated runner actors' do
      Legion::Settings[:extensions][:llm] ||= {}
      Legion::Settings[:extensions][:llm][:ledger] = { remote_invocable: true }

      expect(described_class.remote_invocable?).to be true
    end
  end
end
