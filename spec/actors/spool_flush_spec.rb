# frozen_string_literal: true

RSpec.describe Legion::Extensions::Llm::Ledger::Actor::SpoolFlush do
  subject(:actor) { described_class.new }

  it 'returns 60 for time' do
    expect(actor.time).to eq(60)
  end

  it 'returns false for run_now?' do
    expect(actor.run_now?).to be false
  end

  it 'returns false for use_runner?' do
    expect(actor.use_runner?).to be false
  end

  it 'returns false for check_subtask?' do
    expect(actor.check_subtask?).to be false
  end

  it 'returns false for generate_task?' do
    expect(actor.generate_task?).to be false
  end

  it 'inherits from Every' do
    expect(described_class.superclass).to eq(Legion::Extensions::Actors::Every)
  end

  describe '#run' do
    it 'does not raise when Legion::LLM::Metering is not defined' do
      expect { actor.run }.not_to raise_error
    end

    it 'calls flush_spool when available' do
      metering_mod = Module.new do
        def self.flush_spool
          :flushed
        end
      end
      stub_const('Legion::LLM::Metering', metering_mod)

      expect(Legion::LLM::Metering).to receive(:flush_spool)
      actor.run
    end

    it 'swallows errors from flush_spool' do
      metering_mod = Module.new do
        def self.flush_spool
          raise StandardError, 'connection lost'
        end
      end
      stub_const('Legion::LLM::Metering', metering_mod)

      expect { actor.run }.not_to raise_error
    end
  end
end
