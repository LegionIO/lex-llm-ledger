# frozen_string_literal: true

Legion::Data::Models.require_sequel_models(%w[
                                             identity/providers
                                             identity/principal
                                             identity/identity
                                           ])
require 'legion/extensions/llm/ledger/runners/identity_resolution'

RSpec.describe Legion::Extensions::Llm::Ledger::Runners::IdentityResolution do
  describe '.normalize_caller' do
    it 'extracts identity from x-legion-identity header' do
      result = described_class.normalize_caller(
        body:    {},
        headers: { 'x-legion-identity' => 'miverso2', 'x-legion-caller-type' => 'human' }
      )
      expect(result[:identity]).to eq('miverso2')
      expect(result[:type]).to eq('human')
    end

    it 'prefers body identity over headers' do
      result = described_class.normalize_caller(
        body:    { identity: { identity: 'sarmst22', type: 'human', credential: 'entra_delegated' } },
        headers: { 'x-legion-identity' => 'fallback' }
      )
      expect(result[:identity]).to eq('sarmst22')
    end

    it 'extracts principal_id from header when present' do
      result = described_class.normalize_caller(
        body:    {},
        headers: { 'x-legion-identity' => 'test', 'x-legion-identity-db-principal-id' => '42' }
      )
      expect(result[:principal_id]).to eq(42)
    end

    it 'returns nil identity when headers and body are empty' do
      result = described_class.normalize_caller(body: {}, headers: {})
      expect(result[:identity]).to be_nil
    end

    it 'handles nil headers gracefully' do
      result = described_class.normalize_caller(
        body:    { identity: { identity: 'test_user' } },
        headers: nil
      )
      expect(result[:identity]).to eq('test_user')
    end

    it 'extracts identity_id from header when present' do
      result = described_class.normalize_caller(
        body:    {},
        headers: { 'x-legion-identity' => 'test', 'x-legion-identity-db-identity-id' => '99' }
      )
      expect(result[:identity_id]).to eq(99)
    end

    it 'ignores zero or negative principal_id headers' do
      result = described_class.normalize_caller(
        body:    {},
        headers: { 'x-legion-identity-db-principal-id' => '0' }
      )
      expect(result[:principal_id]).to be_nil
    end

    it 'extracts identity from body caller.requested_by when header is absent' do
      result = described_class.normalize_caller(
        body:    { caller: { requested_by: { identity: 'fallback_caller' } } },
        headers: {}
      )
      expect(result[:identity]).to eq('fallback_caller')
    end
  end

  describe '.resolve_refs' do
    it 'creates identity triad and returns refs' do
      result = described_class.resolve_refs(
        body:    { identity: { identity: 'testuser', type: 'human', credential: 'local' } },
        headers: {}
      )
      expect(result[:principal_id]).to be_a(Integer)
      expect(result[:identity_id]).to be_a(Integer)
      expect(result[:canonical_name]).to eq('testuser')
    end

    it 'returns explicit IDs when provided without DB lookup' do
      result = described_class.resolve_refs(
        body:    {},
        headers: {
          'x-legion-identity'                 => 'someone',
          'x-legion-identity-db-principal-id' => '7',
          'x-legion-identity-db-identity-id'  => '12'
        }
      )
      expect(result[:principal_id]).to eq(7)
      expect(result[:identity_id]).to eq(12)
    end

    it 'is idempotent — second call returns same IDs' do
      params = { body: { identity: { identity: 'idempotent_user', type: 'human' } }, headers: {} }
      first  = described_class.resolve_refs(**params)
      second = described_class.resolve_refs(**params)
      expect(second[:principal_id]).to eq(first[:principal_id])
      expect(second[:identity_id]).to eq(first[:identity_id])
    end

    it 'strips type prefix from canonical_name for prefixed identities' do
      result = described_class.resolve_refs(
        body:    { identity: { identity: 'service:my-daemon' } },
        headers: {}
      )
      expect(result[:canonical_name]).to eq('my-daemon')
    end

    it 'returns empty hash when no identity is present' do
      result = described_class.resolve_refs(body: {}, headers: {})
      expect(result).not_to have_key(:principal_id)
      expect(result).not_to have_key(:identity_id)
    end
  end

  describe '.canonical_name' do
    it 'returns the identity string from header' do
      result = described_class.canonical_name(
        body:    {},
        headers: { 'x-legion-identity' => 'matt@example.com' }
      )
      expect(result).to eq('matt@example.com')
    end

    it 'strips the type prefix when present' do
      result = described_class.canonical_name(
        body:    { identity: { identity: 'human:alice' } },
        headers: {}
      )
      expect(result).to eq('alice')
    end

    it 'returns nil when no identity present' do
      expect(described_class.canonical_name(body: {}, headers: {})).to be_nil
    end
  end

  describe '.identity_tables_available?' do
    it 'returns true when identity models are loaded and connected' do
      expect(described_class.identity_tables_available?).to be(true)
    end
  end
end
