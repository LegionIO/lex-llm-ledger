# frozen_string_literal: true

require 'legion/logging'
require_relative '../../lib/legion/extensions/llm/ledger/helpers/stable_identifiers'

RSpec.describe Legion::Extensions::Llm::Ledger::Helpers::StableIdentifiers do
  describe '.stable_uuid' do
    it 'returns the input unchanged if it is a valid UUID' do
      uuid = '7bf0dcda-c2c3-4e3a-92af-665af3292c56'
      expect(described_class.stable_uuid(uuid)).to eq(uuid)
    end

    it 'returns the input unchanged if it is a short identifier (<=36 chars)' do
      expect(described_class.stable_uuid('conv_123')).to eq('conv_123')
    end

    it 'derives a deterministic UUID for long strings' do
      long = 'llm_message_inference_requests:conv-123'
      result = described_class.stable_uuid(long)
      expect(result.length).to eq(36)
      # Verify stable - second call returns the same UUID
      expect(described_class.stable_uuid(long)).to eq(result)
    end

    it 'produces RFC 4122 UUID format' do
      long = 'llm_message_inference_requests:conv-123'
      result = described_class.stable_uuid(long)
      expect(result).to match(/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/)
    end
  end

  describe '.deterministic_uuid' do
    it 'always derives a UUID, never passes through verbatim' do
      uuid = '7bf0dcda-c2c3-4e3a-92af-665af3292c56'
      result = described_class.deterministic_uuid(uuid)
      expect(result).not_to eq(uuid)
      expect(result.length).to eq(36)
    end

    it 'produces the same UUID for the same input' do
      input = 'some-unique-seed-value'
      expect(described_class.deterministic_uuid(input)).to eq(
        described_class.deterministic_uuid(input)
      )
    end

    it 'produces different UUIDs for different inputs' do
      a = described_class.deterministic_uuid('seed-a')
      b = described_class.deterministic_uuid('seed-b')
      expect(a).not_to eq(b)
    end
  end
end
