# frozen_string_literal: true

RSpec.describe Legion::Extensions::Llm::Ledger::Runners::Metering do
  let(:payload) do
    {
      message_context:   {
        conversation_id:   'conv_123',
        message_id:        'msg_005',
        parent_message_id: 'msg_004',
        message_seq:       5,
        request_id:        'req_abc',
        exchange_id:       'exch_001'
      },
      request_type:      'chat',
      tier:              'fleet',
      provider:          'ollama',
      provider_instance: 'local',
      model_id:          'qwen3.5:27b',
      node_id:           'laptop-matt-01',
      worker_id:         'gpu-h100-01',
      agent_id:          'gaia',
      task_id:           'task_abc',
      input_tokens:      42,
      output_tokens:     28,
      thinking_tokens:   0,
      total_tokens:      70,
      latency_ms:        1245,
      wall_clock_ms:     1300,
      cost_usd:          0.0,
      routing_reason:    'fleet_gpu_available',
      recorded_at:       '2026-04-08T14:30:01.300Z',
      billing:           {
        cost_center: 'engineering-platform',
        budget_id:   'budget_q1_2026'
      }
    }
  end

  let(:metadata) do
    {
      properties: {
        message_id:     'meter_abc123',
        correlation_id: 'req_abc'
      }
    }
  end

  describe '.insert' do
    it 'inserts official lifecycle metric rows and returns ok' do
      result = described_class.insert(payload: payload, metadata: metadata)
      expect(result).to include(result: :ok)

      request = Legion::Data::Models::LLM::MessageInferenceRequest.first
      response = Legion::Data::Models::LLM::MessageInferenceResponse.first
      metric = Legion::Data::Models::LLM::MessageInferenceMetric.first

      expect(request[:request_ref]).to eq('req_abc')
      expect(request[:operation]).to eq('chat')
      expect(response[:provider]).to eq('ollama')
      expect(response[:provider_instance]).to eq('local')
      expect(response[:model_key]).to eq('qwen3.5:27b')
      expect(response[:dispatch_path]).to eq('fleet')
      expect(metric[:input_tokens]).to eq(42)
      expect(metric[:output_tokens]).to eq(28)
      expect(metric[:thinking_tokens]).to eq(0)
      expect(metric[:total_tokens]).to eq(70)
      expect(metric[:latency_ms]).to eq(1245)
      expect(metric[:wall_clock_ms]).to eq(1300)
      expect(metric[:cost_center]).to eq('engineering-platform')
      expect(metric[:budget_key]).to eq('budget_q1_2026')
    end

    it 'is idempotent on second insert with same message_id' do
      described_class.insert(payload: payload, metadata: metadata)
      result = described_class.insert(payload: payload, metadata: metadata)

      expect(result).to include(result: :ok)
      expect(Legion::Data::Models::LLM::MessageInferenceMetric.count).to eq(1)
    end

    it 'handles nil billing block' do
      payload.delete(:billing)
      result = described_class.insert(payload: payload, metadata: metadata)
      expect(result).to include(result: :ok)

      row = Legion::Data::Models::LLM::MessageInferenceMetric.first
      expect(row[:cost_center]).to be_nil
      expect(row[:budget_key]).to be_nil
    end

    it 'stores zero thinking_tokens' do
      payload[:thinking_tokens] = 0
      described_class.insert(payload: payload, metadata: metadata)
      row = Legion::Data::Models::LLM::MessageInferenceMetric.first
      expect(row[:thinking_tokens]).to eq(0)
    end

    it 'converts nil token values to zero' do
      payload[:thinking_tokens] = nil
      described_class.insert(payload: payload, metadata: metadata)
      row = Legion::Data::Models::LLM::MessageInferenceMetric.first
      expect(row[:thinking_tokens]).to eq(0)
    end

    it 'prefers current transport publisher identity over stale caller ids' do
      payload[:caller] = {
        requested_by: {
          id:       'system:system',
          identity: 'system',
          type:     'service'
        }
      }
      payload[:identity] = { identity: 'matt@example.com', type: 'human' }
      metadata[:headers] = {
        'x-legion-identity'    => 'matt@example.com',
        'x-legion-caller-type' => 'human'
      }

      official_payload = described_class.send(
        :official_metering_payload,
        payload,
        payload[:message_context],
        metadata[:properties],
        metadata[:headers]
      )

      expect(official_payload[:caller_identity]).to eq('matt@example.com')
      expect(official_payload[:caller_type]).to eq('human')
    end

    it 'prefers normalized event identity over ambiguous display identity' do
      payload[:caller] = { requested_by: { identity: 'system', type: 'service' } }
      payload[:identity] = { identity: 'matt@example.com', type: 'human' }

      official_payload = described_class.send(
        :official_metering_payload,
        payload,
        payload[:message_context],
        metadata[:properties],
        metadata[:headers]
      )

      expect(official_payload[:caller_identity]).to eq('matt@example.com')
      expect(official_payload[:caller_type]).to eq('human')
    end
  end

  # PRESERVATION CONTRACT — verify runtime invariants before the runner rewrite.
  # Each spec must continue to pass after persistence is extracted into helpers.
  describe 'preservation contract' do
    # All assertions use Legion::Data::Models::LLM::X directly.

    let(:metering_metadata) do
      { properties: { message_id: 'meter_abc123', correlation_id: 'req-ordered' } }
    end

    let(:prompt_metadata) do
      {
        properties: { message_id: 'audit_prompt_123', correlation_id: 'req-ordered', content_encoding: 'identity' },
        headers:    {
          'x-legion-retention'        => 'default',
          'x-legion-contains-phi'     => 'false',
          'x-legion-classification'   => 'internal',
          'x-legion-llm-request-type' => 'chat'
        }
      }
    end

    let(:prompt_payload) do
      {
        message_context: { conversation_id: 'conv_123', request_id: request_id },
        routing:         { provider: 'ollama', model: 'qwen3.5:27b', tier: 'fleet', instance: 'local' },
        tokens:          { input: 42, output: 28, total: 70 },
        request:         { messages: [{ role: 'user', content: 'Hello' }] },
        response:        { message: { role: 'assistant', content: 'Hi' } }
      }
    end

    let(:metering_payload) do
      {
        message_context: { conversation_id: 'conv_123', request_id: request_id },
        request_type:    'chat',
        provider:        'ollama',
        model_id:        'qwen3.5:27b',
        input_tokens:    42,
        output_tokens:   28,
        total_tokens:    70
      }
    end

    let(:thin_metering_payload) do
      { provider: 'ollama', model_id: 'qwen3.5:27b', input_tokens: 10, output_tokens: 5, total_tokens: 15 }
    end
    let(:thin_metering_metadata) { { properties: { message_id: 'thin-1' } } }

    context 'cross-runner ordering invariants' do
      let(:request_id) { 'req-ordered' }

      it 'keeps one request, one response, one metric for prompt-first' do
        Legion::Extensions::Llm::Ledger::Runners::Prompts.insert(
          payload:  prompt_payload,
          metadata: prompt_metadata
        )
        described_class.insert(payload: metering_payload, metadata: metering_metadata)

        expect(Legion::Data::Models::LLM::MessageInferenceRequest.count).to eq(1)
        expect(Legion::Data::Models::LLM::MessageInferenceResponse.count).to eq(1)
        expect(Legion::Data::Models::LLM::MessageInferenceMetric.count).to eq(1)
      end

      it 'keeps one request, one response, one metric for metering-first' do
        described_class.insert(payload: metering_payload, metadata: metering_metadata)
        Legion::Extensions::Llm::Ledger::Runners::Prompts.insert(
          payload:  prompt_payload,
          metadata: prompt_metadata
        )

        expect(Legion::Data::Models::LLM::MessageInferenceRequest.count).to eq(1)
        expect(Legion::Data::Models::LLM::MessageInferenceResponse.count).to eq(1)
        expect(Legion::Data::Models::LLM::MessageInferenceMetric.count).to eq(1)
      end
    end

    context 'idempotency and redelivery' do
      let(:request_id) { 'req-audit-1' }

      it 'is idempotent when the same metering payload is delivered twice' do
        2.times { described_class.insert(payload: metering_payload, metadata: metering_metadata) }
        expect(Legion::Data::Models::LLM::MessageInferenceMetric.count).to eq(1)
      end

      it 'is idempotent when the same prompt payload is delivered twice' do
        2.times do
          Legion::Extensions::Llm::Ledger::Runners::Prompts.insert(
            payload:  prompt_payload,
            metadata: prompt_metadata
          )
        end
        expect(Legion::Data::Models::LLM::MessageInferenceRequest.count).to eq(1)
      end
    end

    context 'string-keyed headers resolution' do
      let(:request_id) { 'req-headers-1' }

      it 'continues to resolve routing fields from string-keyed headers' do
        payload = { request_id: request_id, input_tokens: 10, output_tokens: 5 }
        metadata = {
          headers:    {
            'x-legion-llm-provider' => 'vllm',
            'x-legion-llm-model'    => 'gemma-4-31b-it',
            'x-legion-llm-tier'     => 'direct'
          },
          properties: { message_id: 'hdr-1' }
        }

        result = described_class.insert(payload: payload, metadata: metadata)
        metric = Legion::Data::Models::LLM::MessageInferenceMetric.first

        expect(result[:result]).to eq(:ok)
        expect(metric.provider).to eq('vllm')
        expect(metric.model_key).to eq('gemma-4-31b-it')
        expect(metric.tier).to eq('direct')
      end
    end

    context 'thin metering payloads' do
      it 'does not create llm_messages rows for thin metering-only payloads' do
        described_class.insert(payload: thin_metering_payload, metadata: thin_metering_metadata)
        expect(Legion::Data::Models::LLM::Message.count).to eq(0)
      end

      it 'preserves orphaned lifecycle behavior for thin metering with no correlating ids' do
        described_class.insert(payload: thin_metering_payload, metadata: thin_metering_metadata)

        expect(Legion::Data::Models::LLM::MessageInferenceRequest.count).to eq(1)
        expect(Legion::Data::Models::LLM::MessageInferenceResponse.count).to eq(1)
        expect(Legion::Data::Models::LLM::MessageInferenceMetric.count).to eq(1)
      end
    end

    context 'kwargs contract' do
      let(:request_id) { 'req-kwargs-1' }

      it 'accepts kwargs entrypoints for metering writes' do
        result = described_class.insert(payload: metering_payload, metadata: metering_metadata, ignored: 'ok')
        expect(result[:result]).to eq(:ok)
      end
    end

    context 'route attempt preservation' do
      let(:request_id) { 'req-route-1' }

      it 'does not create route attempts for metering without route_attempt_details' do
        described_class.insert(payload: metering_payload, metadata: metering_metadata)
        expect(Legion::Data::Models::LLM::RouteAttempt.count).to eq(0)
      end
    end

    context 'conversation dedup' do
      let(:request_id) { 'req-conv-dedup-1' }

      it 'preserves mixed conversation id semantics across identifier formats' do
        conv_a_payload = metering_payload.merge(
          message_context: { conversation_id: 'conv_23b2e22115f141b5', request_id: 'req-conv-a' },
          provider:        'ollama'
        )
        conv_a_metadata = { properties: { message_id: 'conv-a-m', correlation_id: 'req-conv-a' } }
        conv_b_payload = metering_payload.merge(
          message_context: { conversation_id: '7bf0dcda-c2c3-4e3a-92af-665af3292c56', request_id: 'req-conv-b' },
          provider:        'ollama'
        )
        conv_b_metadata = { properties: { message_id: 'conv-b-m', correlation_id: 'req-conv-b' } }

        described_class.insert(payload: conv_a_payload, metadata: conv_a_metadata)
        described_class.insert(payload: conv_b_payload, metadata: conv_b_metadata)

        expect(Legion::Data::Models::LLM::Conversation.count).to eq(2)
      end
    end
  end
end
