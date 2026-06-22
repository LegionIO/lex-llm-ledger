# frozen_string_literal: true

require 'legion/logging'
require_relative '../../lib/legion/extensions/llm/ledger/helpers/request_refs'

RSpec.describe Legion::Extensions::Llm::Ledger::Helpers::RequestRefs do
  describe '.request_ref' do
    it 'prefers explicit request_id over correlation_id' do
      body = { request_id: 'req-abc', correlation_id: 'corr-xyz' }
      expect(described_class.request_ref(body)).to eq('req-abc')
    end

    it 'falls back to correlation_id when request_id is absent' do
      body = { correlation_id: 'corr-xyz' }
      expect(described_class.request_ref(body)).to eq('corr-xyz')
    end

    it 'generates a random uuid when no ref is present' do
      body = { foo: 'bar' }
      ref = described_class.request_ref(body)
      expect(ref).to match(/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/)
    end

    it 'memoizes the result on the body for idempotency' do
      body = { foo: 'bar' }
      ref1 = described_class.request_ref(body)
      ref2 = described_class.request_ref(body)
      expect(ref1).to eq(ref2)
    end

    it 'memoizes on body key so subsequent lookups return the cached value' do
      body = { correlation_id: 'corr-1' }
      described_class.request_ref(body)
      body.delete(:correlation_id)
      expect(described_class.request_ref(body)).to eq('corr-1')
    end
  end

  describe '.explicit_request_ref' do
    it 'returns request_id when present' do
      body = { request_id: 'req-123' }
      expect(described_class.explicit_request_ref(body)).to eq('req-123')
    end

    it 'falls back to request_ref key' do
      body = { request_ref: 'ref-456' }
      expect(described_class.explicit_request_ref(body)).to eq('ref-456')
    end

    it 'returns nil when neither key is present' do
      expect(described_class.explicit_request_ref({})).to be_nil
    end
  end

  describe '.correlation_id' do
    it 'extracts from correlation_id' do
      body = { correlation_id: 'corr-123' }
      expect(described_class.correlation_id(body)).to eq('corr-123')
    end

    it 'falls back to tracing correlation_id' do
      body = { tracing: { correlation_id: 'trace-456' } }
      expect(described_class.correlation_id(body)).to eq('trace-456')
    end

    it 'prefers correlation_id over tracing' do
      body = { correlation_id: 'corr-123', tracing: { correlation_id: 'trace-456' } }
      expect(described_class.correlation_id(body)).to eq('corr-123')
    end
  end

  describe '.reference' do
    it 'returns nil when no key matches' do
      expect(described_class.reference({}, :correlation_id)).to be_nil
    end

    it 'returns the first present value' do
      body = { correlation_id: 'corr-1' }
      expect(described_class.reference(body, :bad_key, :correlation_id)).to eq('corr-1')
    end

    it 'coerces to string' do
      body = { request_id: 123 }
      expect(described_class.request_ref(body)).to eq('123')
    end
  end
end
