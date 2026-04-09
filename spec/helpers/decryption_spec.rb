# frozen_string_literal: true

RSpec.describe Legion::Extensions::Llm::Ledger::Helpers::Decryption do
  let(:cleartext_payload) { { message_context: { conversation_id: 'conv_123' }, data: 'hello' } }

  describe '.decrypt_if_needed' do
    context 'with identity encoding (cleartext)' do
      it 'returns symbolized hash unchanged' do
        metadata = { properties: { content_encoding: 'identity' } }
        result = described_class.decrypt_if_needed(cleartext_payload, metadata)
        expect(result[:data]).to eq('hello')
        expect(result[:message_context][:conversation_id]).to eq('conv_123')
      end
    end

    context 'with nil content_encoding' do
      it 'returns symbolized hash' do
        result = described_class.decrypt_if_needed(cleartext_payload, {})
        expect(result[:data]).to eq('hello')
      end
    end

    context 'with encrypted/cs encoding' do
      let(:decrypted_json) { '{"message_context":{"conversation_id":"conv_123"},"data":"secret"}' }

      before do
        crypt_mod = Module.new do
          def self.decrypt(_raw, _init_vec)
            '{"message_context":{"conversation_id":"conv_123"},"data":"secret"}'
          end
        end
        stub_const('Legion::Crypt', crypt_mod)
        stub_const('Legion::Crypt::DecryptionError', Class.new(StandardError))
      end

      it 'decrypts and returns parsed body' do
        metadata = {
          properties: { content_encoding: 'encrypted/cs' },
          headers:    { 'iv' => 'base64iv==' }
        }
        result = described_class.decrypt_if_needed('encrypted_blob', metadata)
        expect(result[:data]).to eq('secret')
        expect(result[:message_context][:conversation_id]).to eq('conv_123')
      end
    end

    context 'when Legion::Crypt is unavailable' do
      it 'raises DecryptionUnavailable' do
        metadata = { properties: { content_encoding: 'encrypted/cs' } }
        expect do
          described_class.decrypt_if_needed('encrypted_blob', metadata)
        end.to raise_error(Legion::Extensions::Llm::Ledger::Helpers::DecryptionUnavailable)
      end
    end

    context 'when decryption fails' do
      before do
        error_class = Class.new(StandardError)
        crypt_mod = Module.new do
          define_method(:decrypt) { |_raw, _iv| raise error_class, 'bad ciphertext' }
          module_function :decrypt
        end
        stub_const('Legion::Crypt', crypt_mod)
        stub_const('Legion::Crypt::DecryptionError', error_class)
      end

      it 'raises DecryptionFailed' do
        metadata = {
          properties: { content_encoding: 'encrypted/cs' },
          headers:    { 'iv' => 'base64iv==' }
        }
        expect do
          described_class.decrypt_if_needed('bad_data', metadata)
        end.to raise_error(Legion::Extensions::Llm::Ledger::Helpers::DecryptionFailed, /bad ciphertext/)
      end
    end
  end
end
