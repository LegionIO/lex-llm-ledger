# frozen_string_literal: true

RSpec.describe Legion::Extensions::Llm::Ledger::Writers::OfficialMeteringWriter do
  let(:payload) do
    {
      request_id:        'req-1',
      conversation_id:   'conv-1',
      operation:         'embed',
      correlation_id:    'corr-1',
      provider:          'ollama',
      provider_instance: 'default',
      model_id:          'mxbai-embed-large:latest',
      input_tokens:      5,
      output_tokens:     0,
      thinking_tokens:   0,
      total_tokens:      5,
      latency_ms:        40,
      wall_clock_ms:     41,
      cost_usd:          0.0,
      recorded_at:       '2026-05-06T14:00:00Z',
      billing:           {
        cost_center: 'engineering-platform',
        budget_id:   'budget-q2'
      }
    }
  end

  it 'persists metering events into official inference metrics' do
    result = described_class.write(payload)

    expect(result[:result]).to eq(:ok)
    request = Legion::Data.connection[:llm_message_inference_requests].first
    response = Legion::Data.connection[:llm_message_inference_responses].first
    metric = Legion::Data.connection[:llm_message_inference_metrics].first

    expect(request[:operation]).to eq('embed')
    expect(response[:provider_instance]).to eq('default')
    expect(metric[:provider]).to eq('ollama')
    expect(metric[:model_key]).to eq('mxbai-embed-large:latest')
    expect(metric[:input_tokens]).to eq(5)
    expect(metric[:budget_key]).to eq('budget-q2')
  end
end
