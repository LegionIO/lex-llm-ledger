# frozen_string_literal: true

RSpec.describe Legion::Extensions::Llm::Ledger::Helpers::PersistenceLogging do
  let(:dataset) { instance_double(Sequel::Dataset) }
  let(:db) { { llm_metering_records: dataset } }
  let(:logger) { instance_double(Logger, info: nil, warn: nil, error: nil) }

  before do
    allow(described_class).to receive(:log).and_return(logger)
    allow(described_class).to receive(:handle_exception)
    allow(dataset).to receive(:first_source).and_return(:llm_metering_records)
  end

  it 'logs successful row inserts at info with safe row context' do
    allow(dataset).to receive(:insert).and_return(42)

    result = described_class.insert_dataset(
      relation:   dataset,
      attributes: { uuid: 'metric_uuid', request_json: '{"secret":"hidden"}' },
      operation:  'write_metering_record'
    )

    expect(result).to eq(42)
    expect(logger).to have_received(:info).with(include(
                                                  'action=ledger.persistence.inserted',
                                                  'table=llm_metering_records',
                                                  'operation=write_metering_record',
                                                  'row_id=42',
                                                  'uuid=metric_uuid'
                                                ))
    expect(logger).not_to have_received(:info).with(include('request_json'))
  end

  it 'logs duplicate insert failures at warn and re-raises' do
    error = Sequel::UniqueConstraintViolation.new('duplicate')
    allow(dataset).to receive(:insert).and_raise(error)

    expect do
      described_class.insert_dataset(relation: dataset, attributes: { uuid: 'metric_uuid' },
                                     operation: 'write_metering_record')
    end.to raise_error(Sequel::UniqueConstraintViolation)

    expect(logger).to have_received(:warn).with(include(
                                                  'action=ledger.persistence.insert_failed',
                                                  'table=llm_metering_records',
                                                  'operation=write_metering_record',
                                                  'error_class=Sequel::UniqueConstraintViolation',
                                                  'uuid=metric_uuid'
                                                ))
  end

  it 'can suppress duplicate insert warnings for caller-handled races' do
    error = Sequel::UniqueConstraintViolation.new('duplicate')
    allow(dataset).to receive(:insert).and_raise(error)

    expect do
      described_class.insert_dataset(relation: dataset, attributes: { uuid: 'metric_uuid' },
                                     operation: 'write_metering_record', warn_on_unique: false)
    end.to raise_error(Sequel::UniqueConstraintViolation)

    expect(logger).not_to have_received(:warn)
  end

  it 'logs unexpected insert failures at error, reports the exception, and re-raises' do
    error = RuntimeError.new('database down')
    allow(dataset).to receive(:insert).and_raise(error)

    expect do
      described_class.insert_dataset(relation: dataset, attributes: { uuid: 'metric_uuid' },
                                     operation: 'write_metering_record')
    end.to raise_error(RuntimeError, /database down/)

    expect(logger).to have_received(:error).with(include(
                                                   'action=ledger.persistence.insert_failed',
                                                   'table=llm_metering_records',
                                                   'operation=write_metering_record',
                                                   'error_class=RuntimeError',
                                                   'uuid=metric_uuid'
                                                 ))
    expect(described_class).to have_received(:handle_exception).with(
      error,
      level:     :error,
      handled:   true,
      operation: 'write_metering_record',
      table:     :llm_metering_records
    )
  end
end
