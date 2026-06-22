# frozen_string_literal: true

require 'legion/logging'
require 'legion/extensions/llm/ledger/helpers/identity_resolution'

RSpec.describe Legion::Extensions::Llm::Ledger::Helpers::IdentityResolution do
  describe '.identity_canonical_name' do
    it 'extracts from identity[:canonical_name]' do
      body = { identity: { canonical_name: 'matt@example.com' } }
      expect(described_class.identity_canonical_name(body)).to eq('matt@example.com')
    end

    it 'falls back to identity[:identity]' do
      body = { identity: { identity: 'user:matt' } }
      expect(described_class.identity_canonical_name(body)).to eq('user:matt')
    end

    it 'falls back to caller_identity' do
      body = { caller_identity: 'service:gaia' }
      expect(described_class.identity_canonical_name(body)).to eq('service:gaia')
    end

    it 'returns nil when no identity is present' do
      expect(described_class.identity_canonical_name({})).to be_nil
    end
  end

  describe '.normalize_caller_type' do
    it 'normalizes :user to :human' do
      expect(described_class.normalize_caller_type(:user)).to eq(:human)
    end

    it 'passes through :human unchanged' do
      expect(described_class.normalize_caller_type(:human)).to eq(:human)
    end

    it 'normalizes :admin to :system' do
      expect(described_class.normalize_caller_type('admin')).to eq(:system)
    end

    it 'passes through :bot unchanged' do
      expect(described_class.normalize_caller_type(:bot)).to eq(:bot)
    end

    it 'returns nil for nil input' do
      expect(described_class.normalize_caller_type(nil)).to be_nil
    end

    it 'returns nil for empty input' do
      expect(described_class.normalize_caller_type('')).to be_nil
    end
  end

  describe '.parsed_identity_descriptor' do
    it 'parses a plain identity string' do
      body = { identity: { identity: 'matt@example.com', type: 'human', credential: 'local' } }
      descriptor = described_class.parsed_identity_descriptor(body)

      expect(descriptor[:canonical_name]).to eq('matt@example.com')
      expect(descriptor[:kind]).to eq(:human)
      expect(descriptor[:provider_identity_key]).to eq('matt@example.com')
      expect(descriptor[:provider_name]).to eq('local')
    end

    it 'unpacks prefixed identity strings like "user:matt"' do
      body = { identity: { identity: 'user:matt', type: 'human' } }
      descriptor = described_class.parsed_identity_descriptor(body)

      expect(descriptor[:canonical_name]).to eq('matt')
      expect(descriptor[:kind]).to eq(:human)
      expect(descriptor[:provider_identity_key]).to eq('user:matt')
    end

    it 'leaves email addresses with colons intact' do
      body = { identity: { identity: 'matt@example.com', type: 'human' } }
      descriptor = described_class.parsed_identity_descriptor(body)

      expect(descriptor[:canonical_name]).to eq('matt@example.com')
    end

    it 'keeps email addresses typed as human when type is human' do
      body = { identity: { identity: 'matt@example.com', type: 'human' } }
      descriptor = described_class.parsed_identity_descriptor(body)

      expect(descriptor[:kind]).to eq(:human)
    end

    it 'defaults to unknown kind when type is nil and no prefix' do
      body = { identity: { identity: 'matt@example.com' } }
      descriptor = described_class.parsed_identity_descriptor(body)

      expect(descriptor[:kind]).to eq('unknown')
    end

    it 'returns empty hash for nil identity' do
      expect(described_class.parsed_identity_descriptor({})).to eq({})
    end
  end

  describe '.normalize_provider_name' do
    it 'strips colon prefix and lowercases' do
      expect(described_class.send(:normalize_provider_name, 'entra:delegated')).to eq('delegated')
      expect(described_class.send(:normalize_provider_name, 'entra')).to eq('entra')
      expect(described_class.send(:normalize_provider_name, 'local')).to eq('local')
      expect(described_class.send(:normalize_provider_name, nil)).to eq('local')
    end
  end
end
