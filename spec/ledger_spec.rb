# frozen_string_literal: true

require 'legion/extensions/llm/ledger'

RSpec.describe Legion::Extensions::Llm::Ledger do
  describe '.default_settings' do
    it 'does not disable extension remote invocation globally' do
      expect(described_class.default_settings).not_to include(:remote_invocable)
    end
  end
end
