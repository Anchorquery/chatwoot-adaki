# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Captain::Assistant::AgentRunnerService do
  let(:account) { create(:account) }
  let(:inbox) { create(:inbox, account: account) }
  let(:contact) { create(:contact, account: account) }
  let(:conversation) { create(:conversation, account: account, inbox: inbox, contact: contact) }
  let(:assistant) { create(:captain_assistant, account: account) }
  let(:scenario) { create(:captain_scenario, assistant: assistant, enabled: true) }

  let(:mock_runner) { instance_double(Agents::AgentRunner) }
  let(:mock_agent) { instance_double(Agents::Agent) }
  let(:mock_scenario_agent) { instance_double(Agents::Agent) }
  let(:mock_result) { instance_double(Agents::RunResult, output: { 'response' => 'Test response' }, context: nil) }

  let(:message_history) do
    [
      { role: 'user', content: 'Hello there' },
      { role: 'assistant', content: 'Hi! How can I help you?', agent_name: 'Assistant' },
      { role: 'user', content: 'I need help with my account' }
    ]
  end

  before do
    allow(assistant).to receive(:agent).and_return(mock_agent)
    scenarios_relation = instance_double(Captain::Scenario)
    allow(scenarios_relation).to receive(:enabled).and_return([scenario])
    allow(assistant).to receive(:scenarios).and_return(scenarios_relation)
    allow(scenario).to receive(:agent).and_return(mock_scenario_agent)
    allow(Agents::Runner).to receive(:with_agents).and_return(mock_runner)
    allow(mock_runner).to receive(:run).and_return(mock_result)
    allow(mock_runner).to receive(:on_tool_complete).and_return(mock_runner)
    allow(mock_runner).to receive(:on_run_complete).and_return(mock_runner)
    allow(mock_runner).to receive(:on_chat_created).and_return(mock_runner)
    allow(mock_agent).to receive(:register_handoffs)
    allow(mock_scenario_agent).to receive(:register_handoffs)
  end

  describe '#initialize' do
    it 'sets instance variables correctly' do
      service = described_class.new(assistant: assistant, conversation: conversation)

      expect(service.instance_variable_get(:@assistant)).to eq(assistant)
      expect(service.instance_variable_get(:@conversation)).to eq(conversation)
      expect(service.instance_variable_get(:@callbacks)).to eq({})
    end

    it 'accepts callbacks parameter' do
      callbacks = { on_agent_thinking: proc { |x| x } }
      service = described_class.new(assistant: assistant, callbacks: callbacks)

      expect(service.instance_variable_get(:@callbacks)).to eq(callbacks)
    end
  end

  describe '#generate_response' do
    subject(:service) { described_class.new(assistant: assistant, conversation: conversation) }

    # gpt-5.4-mini, account 4, 2026-09-04: the provider answered 400 to the
    # reasoning_effort we guessed and the customer got a handoff.
    context 'when the provider rejects the reasoning params' do
      let(:rejected_result) do
        instance_double(
          Agents::RunResult,
          output: nil,
          context: {},
          error: RubyLLM::BadRequestError.new("Unsupported value: 'reasoning_effort' does not support 'minimal' with this model.")
        )
      end
      let(:retry_result) { instance_double(Agents::RunResult, output: { 'response' => 'Tenemos manoplas de depilación.' }, context: {}) }

      before { allow(mock_runner).to receive(:run).and_return(rejected_result, retry_result) }

      it 'rebuilds the agents without the params and replays the turn instead of handing off' do
        allow(Llm::Thinking).to receive(:without_params).and_call_original

        response = service.generate_response(message_history: message_history)

        expect(response['response']).to eq('Tenemos manoplas de depilación.')
        expect(Llm::Thinking).to have_received(:without_params).once
        expect(mock_runner).to have_received(:run).twice
        expect(Agents::Runner).to have_received(:with_agents).twice
      end

      it 'replays with the learned efforts (no kill switch) when the provider listed them' do
        allow(Llm::ReasoningCapabilities).to receive(:learn_from_rejection!).and_return(%w[none low medium high xhigh])
        allow(Llm::Thinking).to receive(:without_params).and_call_original

        response = service.generate_response(message_history: message_history)

        expect(response['response']).to eq('Tenemos manoplas de depilación.')
        expect(Llm::ReasoningCapabilities).to have_received(:learn_from_rejection!).once
        expect(Llm::Thinking).not_to have_received(:without_params)
        expect(mock_runner).to have_received(:run).twice
      end

      it 'gives up after one retry when the replay is rejected too' do
        allow(mock_runner).to receive(:run).and_return(rejected_result, rejected_result)

        response = service.generate_response(message_history: message_history)

        expect(mock_runner).to have_received(:run).twice
        expect(response['error']).to include('reasoning_effort')
      end
    end

    it 'builds agents and wires them together' do
      expect(assistant).to receive(:agent).and_return(mock_agent)
      scenarios_relation = instance_double(Captain::Scenario)
      allow(scenarios_relation).to receive(:enabled).and_return([scenario])
      expect(assistant).to receive(:scenarios).and_return(scenarios_relation)
      expect(scenario).to receive(:agent).and_return(mock_scenario_agent)
      expect(mock_agent).to receive(:register_handoffs).with(mock_scenario_agent)
      expect(mock_scenario_agent).to receive(:register_handoffs).with(mock_agent)

      service.generate_response(message_history: message_history)
    end

    it 'creates runner with agents' do
      expect(Agents::Runner).to receive(:with_agents).with(mock_agent, mock_scenario_agent)

      service.generate_response(message_history: message_history)
    end

    it 'runs agent with extracted user message and context' do
      expected_context = hash_including(
        session_id: "#{account.id}_#{conversation.display_id}",
        conversation_history: [
          { role: :user, content: 'Hello there', agent_name: nil },
          { role: :assistant, content: 'Hi! How can I help you?', agent_name: 'Assistant' }
        ],
        state: hash_including(
          account_id: account.id,
          assistant_id: assistant.id,
          conversation: hash_including(id: conversation.id),
          contact: hash_including(id: contact.id)
        )
      )

      expect(mock_runner).to receive(:run).with(
        'I need help with my account',
        context: expected_context,
        max_turns: described_class::MAX_TURNS
      )

      service.generate_response(message_history: message_history)
    end

    context 'when the latest user message is multimodal' do
      let(:multimodal_message_history) do
        [
          { role: 'assistant', content: 'Please share a screenshot' },
          {
            role: 'user',
            content: [
              { type: 'text', text: 'What does this error mean?' },
              { type: 'image_url', image_url: { url: 'https://example.com/error.png' } }
            ]
          }
        ]
      end

      it 'passes image attachments to the runner input' do
        expect(mock_runner).to receive(:run) do |input, context:, max_turns:|
          expect(input).to be_a(RubyLLM::Content)
          expect(input.text).to eq('What does this error mean?')
          expect(input.attachments.first.source.to_s).to eq('https://example.com/error.png')
          expect(context[:conversation_history]).to eq([{ role: :assistant, content: 'Please share a screenshot', agent_name: nil }])
          expect(max_turns).to eq(described_class::MAX_TURNS)
        end

        service.generate_response(message_history: multimodal_message_history)
      end

      it 'preserves multimodal content in earlier history messages' do
        history_with_prior_image = [
          {
            role: 'user',
            content: [
              { type: 'text', text: 'Here is my error screenshot' },
              { type: 'image_url', image_url: { url: 'https://example.com/error.png' } }
            ]
          },
          { role: 'assistant', content: 'I see the error. Try restarting.' },
          { role: 'user', content: 'It still does not work' }
        ]

        expect(mock_runner).to receive(:run) do |input, context:, max_turns:|
          expect(input).to eq('It still does not work')
          # The earlier user message with the image should preserve the multimodal array
          first_history_msg = context[:conversation_history].first
          expect(first_history_msg[:content]).to be_a(Array)
          expect(first_history_msg[:content]).to include(
            { type: 'text', text: 'Here is my error screenshot' },
            { type: 'image_url', image_url: { url: 'https://example.com/error.png' } }
          )
          expect(max_turns).to eq(described_class::MAX_TURNS)
        end

        service.generate_response(message_history: history_with_prior_image)
      end

      it 'stores multimodal trace payloads in runner context' do
        expect(mock_runner).to receive(:run) do |_input, context:, max_turns:|
          expect(context[:captain_v2_trace_input]).to include('image_url')
          expect(context[:captain_v2_trace_current_input]).to include('image_url')
          expect(max_turns).to eq(described_class::MAX_TURNS)
        end

        service.generate_response(message_history: multimodal_message_history)
      end
    end

    it 'processes and formats agent result' do
      result = service.generate_response(message_history: message_history)

      expect(result).to eq({ 'response' => 'Test response', 'agent_name' => nil, 'handoff_tool_called' => false })
    end

    context 'when the agent replies with only a promise and calls no content tool' do
      let(:promise_result) do
        instance_double(Agents::RunResult, output: { 'response' => 'Let me check that for you' }, context: {})
      end
      let(:retry_result) do
        instance_double(Agents::RunResult, output: { 'response' => 'Here is the answer: 42' }, context: {})
      end

      before do
        allow(mock_runner).to receive(:run).and_return(promise_result, retry_result)
      end

      it 'retries once and uses the retry reply' do
        result = service.generate_response(message_history: message_history)

        expect(mock_runner).to have_received(:run).twice
        expect(result['response']).to eq('Here is the answer: 42')
      end

      it 'replays with the internal nudge and the first run context' do
        service.generate_response(message_history: message_history)

        expect(mock_runner).to have_received(:run).with(
          described_class::RETRY_NUDGE, context: promise_result.context, max_turns: described_class::MAX_TURNS
        )
      end

      context 'when the retry is also a promise-only reply' do
        let(:retry_result) do
          instance_double(Agents::RunResult, output: { 'response' => 'Let me check that for you' }, context: {})
        end

        it 'keeps the original reply instead of the still-unhelpful retry' do
          result = service.generate_response(message_history: message_history)

          expect(result['response']).to eq('Let me check that for you')
        end
      end

      context 'when the retry echoes the internal nudge marker' do
        let(:retry_result) do
          instance_double(Agents::RunResult, output: { 'response' => "#{described_class::RETRY_NUDGE_MARKER} here you go" }, context: {})
        end

        it 'discards the retry so the internal marker never reaches the customer' do
          result = service.generate_response(message_history: message_history)

          expect(result['response']).to eq('Let me check that for you')
        end
      end

      context 'when the retry comes back blank' do
        let(:retry_result) { instance_double(Agents::RunResult, output: { 'response' => '' }, context: {}) }

        it 'keeps the original reply' do
          result = service.generate_response(message_history: message_history)

          expect(result['response']).to eq('Let me check that for you')
        end
      end
    end

    context 'when the agent replies with an empty message (production conversation 309, 2026-09-04)' do
      let(:empty_result) { instance_double(Agents::RunResult, output: '', context: {}) }
      let(:retry_result) { instance_double(Agents::RunResult, output: 'Tenemos soportes y tarjetas NFC.', context: {}) }

      before do
        allow(mock_runner).to receive(:run).and_return(empty_result, retry_result)
      end

      it 'retries once with the empty-reply nudge and uses the retry reply' do
        result = service.generate_response(message_history: message_history)

        expect(mock_runner).to have_received(:run).with(
          described_class::EMPTY_REPLY_NUDGE, context: empty_result.context, max_turns: described_class::MAX_TURNS
        )
        expect(result['response']).to eq('Tenemos soportes y tarjetas NFC.')
      end

      context 'when the retry is empty too' do
        let(:retry_result) { instance_double(Agents::RunResult, output: { 'response' => '' }, context: {}) }

        it 'sends the empty-reply fallback instead of a blank reply (which the job would turn into a handoff)' do
          result = service.generate_response(message_history: message_history)

          expect(result['response']).to eq(I18n.t('conversations.captain.empty_reply_fallback'))
          expect(result['handoff_tool_called']).to be(false)
        end
      end

      context 'when the empty reply came with a real handoff' do
        let(:empty_result) { instance_double(Agents::RunResult, output: '', context: { captain_v2_handoff_tool_called: true }) }

        it 'does not retry and keeps the handoff signal' do
          result = service.generate_response(message_history: message_history)

          expect(mock_runner).to have_received(:run).once
          expect(result['handoff_tool_called']).to be(true)
        end
      end
    end

    context 'when a scenario echoes the internal ai-agents handoff payload' do
      let(:internal_result) do
        instance_double(
          Agents::RunResult,
          output: { 'response' => "I'll transfer you to scenario_34_informacion_sobre_produc_agent who can better assist you with this." },
          context: { current_agent: 'scenario_34_informacion_sobre_produc_agent' }
        )
      end
      let(:retry_result) do
        instance_double(Agents::RunResult, output: { 'response' => 'Tenemos soportes y tarjetas NFC.' }, context: {})
      end

      before { allow(mock_runner).to receive(:run).and_return(internal_result, retry_result) }

      it 'retries with a completion nudge and never publishes the routing text' do
        result = service.generate_response(message_history: message_history)

        expect(mock_runner).to have_received(:run).with(
          described_class::INTERNAL_HANDOFF_NUDGE, context: internal_result.context, max_turns: described_class::MAX_TURNS
        )
        expect(result['response']).to eq('Tenemos soportes y tarjetas NFC.')
      end
    end

    context 'when a content tool already ran during the turn' do
      let(:mock_result) do
        instance_double(
          Agents::RunResult, output: { 'response' => 'Let me check that for you' }, context: { captain_v2_content_tool_calls: 1 }
        )
      end

      it 'does not retry, even if the text looks like a promise' do
        service.generate_response(message_history: message_history)

        expect(mock_runner).to have_received(:run).once
      end
    end

    context 'when the handoff tool already fired during the turn' do
      let(:mock_result) do
        instance_double(
          Agents::RunResult, output: { 'response' => 'Let me check that for you' }, context: { captain_v2_handoff_tool_called: true }
        )
      end

      it 'does not retry' do
        service.generate_response(message_history: message_history)

        expect(mock_runner).to have_received(:run).once
      end
    end

    context 'when the reply is a genuine answer' do
      it 'does not retry' do
        service.generate_response(message_history: message_history)

        expect(mock_runner).to have_received(:run).once
      end
    end

    context 'when handoff tool was called during agent execution' do
      let(:runner_context) { { captain_v2_handoff_tool_called: true } }
      let(:mock_result) do
        instance_double(Agents::RunResult, output: { 'response' => 'Let me connect you' }, context: runner_context)
      end

      it 'includes handoff_tool_called flag in response' do
        result = service.generate_response(message_history: message_history)

        expect(result).to eq({
                               'response' => 'Let me connect you',
                               'agent_name' => nil,
                               'handoff_tool_called' => true
                             })
      end
    end

    context 'when the reply falsely claims a handoff without the tool having fired' do
      let(:mock_result) do
        instance_double(
          Agents::RunResult,
          output: { 'response' => 'Se ha transferido la conversación al agente de información de productos' },
          context: {}
        )
      end

      it 'suppresses the reply and replaces it with a safe fallback' do
        result = service.generate_response(message_history: message_history)

        expect(result['response']).to eq(I18n.t('conversations.captain.handoff_announcement_leak_fallback'))
        expect(result['handoff_tool_called']).to be(false)
      end

      it 'logs the suppression instead of silently swallowing it' do
        allow(Rails.logger).to receive(:warn)

        service.generate_response(message_history: message_history)

        expect(Rails.logger).to have_received(:warn).with(a_string_including('Suppressed a reply that falsely claimed a handoff'))
      end
    end

    context 'when the reply falsely claims a transfer to a human in the first person (production conversation 120, 2026-09-04)' do
      let(:mock_result) do
        instance_double(
          Agents::RunResult,
          output: { 'response' => 'Te transfiero con un agente humano para que te pueda ayudar.' },
          context: {}
        )
      end

      it 'suppresses it like any other unbacked handoff announcement' do
        result = service.generate_response(message_history: message_history)

        expect(result['response']).to eq(I18n.t('conversations.captain.handoff_announcement_leak_fallback'))
      end
    end

    describe 'HANDOFF_ANNOUNCEMENT_LEAK_PATTERN' do
      let(:pattern) { described_class::HANDOFF_ANNOUNCEMENT_LEAK_PATTERN }

      [
        'Te transfiero con un agente humano para que te pueda ayudar.',
        'Se ha transferido la conversación al agente de productos.',
        'Te voy a pasar con un compañero de soporte.',
        'Voy a transferirte con soporte ahora mismo.',
        "I'll transfer you to scenario_34_informacion_sobre_produc_agent who can better assist you with this.",
        'Le pongo en contacto con un agente.',
        'Hablarás con un agente en breve.',
        'Te comunico con una persona del equipo.',
        "I've transferred you to a human agent."
      ].each do |leak|
        it "matches #{leak.inspect}" do
          expect(leak).to match(pattern)
        end
      end

      [
        'La transferencia bancaria tarda 24 horas en reflejarse.',
        '¿Quieres que te ayude con la activación de la tarjeta?',
        'El envío es gratuito en todos los pedidos.',
        'Puedes transferir el saldo desde tu cuenta.'
      ].each do |safe|
        it "leaves #{safe.inspect} alone" do
          expect(safe).not_to match(pattern)
        end
      end
    end

    context 'when the reply mentions a transfer AND the handoff tool actually fired' do
      let(:mock_result) do
        instance_double(
          Agents::RunResult,
          output: { 'response' => 'Se ha transferido la conversación al agente de información de productos' },
          context: { captain_v2_handoff_tool_called: true }
        )
      end

      it 'does not suppress a legitimate handoff message' do
        result = service.generate_response(message_history: message_history)

        expect(result['response']).to eq('Se ha transferido la conversación al agente de información de productos')
      end
    end

    context 'when no scenarios are enabled' do
      before do
        scenarios_relation = instance_double(Captain::Scenario)
        allow(scenarios_relation).to receive(:enabled).and_return([])
        allow(assistant).to receive(:scenarios).and_return(scenarios_relation)
      end

      it 'only uses assistant agent' do
        expect(Agents::Runner).to receive(:with_agents).with(mock_agent)
        expect(mock_agent).not_to receive(:register_handoffs)

        service.generate_response(message_history: message_history)
      end
    end

    context 'when agent result is a string' do
      let(:mock_result) { instance_double(Agents::RunResult, output: 'Simple string response', context: nil) }

      it 'formats string response correctly' do
        result = service.generate_response(message_history: message_history)

        expect(result).to eq({
                               'response' => 'Simple string response',
                               'reasoning' => 'Processed by agent',
                               'agent_name' => nil,
                               'handoff_tool_called' => false
                             })
      end
    end

    context 'when an error occurs' do
      let(:error) { StandardError.new('Test error') }

      before do
        allow(mock_runner).to receive(:run).and_raise(error)
        allow(ChatwootExceptionTracker).to receive(:new).and_return(
          instance_double(ChatwootExceptionTracker, capture_exception: true)
        )
      end

      it 'captures exception and returns error response' do
        expect(ChatwootExceptionTracker).to receive(:new).with(error, account: conversation.account)

        result = service.generate_response(message_history: message_history)

        expect(result).to eq({
                               'response' => 'conversation_handoff',
                               'reasoning' => 'Error occurred: Test error',
                               'error' => 'Test error',
                               'failure_class' => 'unknown',
                               'handoff_tool_called' => false
                             })
      end

      it 'logs error details' do
        expect(Rails.logger).to receive(:error).with('[Captain V2] AgentRunnerService error: Test error')
        expect(Rails.logger).to receive(:error).with(kind_of(String))

        service.generate_response(message_history: message_history)
      end

      context 'when conversation is nil' do
        subject(:service) { described_class.new(assistant: assistant, conversation: nil) }

        it 'handles missing conversation gracefully' do
          expect(ChatwootExceptionTracker).to receive(:new).with(error, account: nil)

          result = service.generate_response(message_history: message_history)

          expect(result).to eq({
                                 'response' => 'conversation_handoff',
                                 'reasoning' => 'Error occurred: Test error',
                                 'error' => 'Test error',
                                 'failure_class' => 'unknown',
                                 'handoff_tool_called' => false
                               })
        end
      end

      context 'when HandoffTool fired before the runner errored' do
        # The stubbed runner never invokes the on_tool_complete callback, so we call
        # track_handoff_usage directly to simulate the flag being set before the raise.
        before do
          allow(mock_runner).to receive(:run) do
            service.send(:track_handoff_usage,
                         Captain::Tools::HandoffTool.new(assistant).name,
                         Captain::Tools::HandoffTool.new(assistant).name,
                         Struct.new(:context).new({}))
            raise error
          end
        end

        it 'surfaces handoff_tool_called in error_response so the job routes to the V2 path' do
          result = service.generate_response(message_history: message_history)

          expect(result).to eq({
                                 'response' => 'conversation_handoff',
                                 'reasoning' => 'Error occurred: Test error',
                                 'error' => 'Test error',
                                 'failure_class' => 'unknown',
                                 'handoff_tool_called' => true
                               })
        end
      end
    end

    # Deliberately a sibling of 'when an error occurs' (not nested in it): that
    # context's `before` makes runner.run raise, which never exercises this
    # path — the ai-agents Runner swallows the LLM error itself and returns it
    # as result.error instead of letting it propagate.
    context 'when the runner catches the LLM error internally (result.error, not a raise)' do
      let(:runner_context) { {} }
      let(:mock_result) do
        instance_double(Agents::RunResult, output: nil, context: runner_context,
                                           error: RubyLLM::UnauthorizedError.new('Incorrect API key provided'))
      end

      it 'classifies the failure so the job can tell a dead credential apart from a transient one' do
        result = service.generate_response(message_history: message_history)

        expect(result['failure_class']).to eq('configuration')
        expect(result['response']).to eq('conversation_handoff')
        expect(result['error']).to eq('Incorrect API key provided')
      end
    end
  end

  describe '#promise_only_text?' do
    subject(:service) { described_class.new(assistant: assistant, conversation: conversation) }

    it 'matches english promise-only replies' do
      expect(service.send(:promise_only_text?, 'Let me check that for you')).to be true
      expect(service.send(:promise_only_text?, 'Give me a moment')).to be true
      expect(service.send(:promise_only_text?, "I'll look that up")).to be true
    end

    it 'matches spanish promise-only replies' do
      expect(service.send(:promise_only_text?, 'Déjame revisar eso')).to be true
      expect(service.send(:promise_only_text?, 'Permíteme buscar la información')).to be true
      expect(service.send(:promise_only_text?, 'Voy a revisar tu cuenta')).to be true
    end

    it 'matches portuguese and french promise-only replies' do
      expect(service.send(:promise_only_text?, 'Vou verificar isso para você')).to be true
      expect(service.send(:promise_only_text?, 'Je vais vérifier ça')).to be true
    end

    it 'does not match a real answer' do
      expect(service.send(:promise_only_text?, 'Your order ships in 3-5 business days.')).to be false
    end

    it 'does not match a clarifying question even if it starts similarly' do
      expect(service.send(:promise_only_text?, 'Let me check — could you confirm your order number?')).to be false
    end

    it 'does not match long replies even if they contain a promise-like phrase' do
      long_text = "Let me check that. #{'a' * 300}"
      expect(service.send(:promise_only_text?, long_text)).to be false
    end

    it 'does not match blank text' do
      expect(service.send(:promise_only_text?, '')).to be false
      expect(service.send(:promise_only_text?, nil)).to be false
    end
  end

  describe '#build_context' do
    subject(:service) { described_class.new(assistant: assistant, conversation: conversation) }

    it 'builds context with conversation history and state' do
      context = service.send(:build_context, message_history)

      expect(context).to include(
        conversation_history: array_including(
          { role: :user, content: 'Hello there', agent_name: nil },
          { role: :assistant, content: 'Hi! How can I help you?', agent_name: 'Assistant' }
        ),
        state: hash_including(
          account_id: account.id,
          assistant_id: assistant.id
        )
      )
    end

    context 'with multimodal content' do
      let(:multimodal_content) do
        [
          { type: 'text', text: 'Can you help with this image?' },
          { type: 'image_url', image_url: { url: 'https://example.com/image.jpg' } }
        ]
      end

      let(:multimodal_message_history) do
        [{ role: 'user', content: multimodal_content }]
      end

      it 'preserves multimodal arrays in conversation history for image context retention' do
        context = service.send(:build_context, multimodal_message_history)

        expect(context[:conversation_history].first[:content]).to eq(multimodal_content)
      end
    end
  end

  describe '#extract_last_user_message' do
    subject(:service) { described_class.new(assistant: assistant, conversation: conversation) }

    it 'extracts the last user message' do
      result = service.send(:extract_last_user_message, message_history)

      expect(result).to eq('I need help with my account')
    end

    it 'returns multimodal content with image attachments for the runner input' do
      multimodal_message_history = [
        {
          role: 'user',
          content: [
            { type: 'text', text: 'Can you check this screenshot?' },
            { type: 'image_url', image_url: { url: 'https://example.com/image.jpg' } }
          ]
        }
      ]

      result = service.send(:extract_last_user_message, multimodal_message_history)

      expect(result).to be_a(RubyLLM::Content)
      expect(result.text).to eq('Can you check this screenshot?')
      expect(result.attachments.first.source.to_s).to eq('https://example.com/image.jpg')
    end
  end

  describe '#extract_text_from_content' do
    subject(:service) { described_class.new(assistant: assistant, conversation: conversation) }

    it 'extracts text from string content' do
      result = service.send(:extract_text_from_content, 'Simple text')

      expect(result).to eq('Simple text')
    end

    it 'extracts response from hash content' do
      content = { 'response' => 'Hash response' }
      result = service.send(:extract_text_from_content, content)

      expect(result).to eq('Hash response')
    end

    it 'extracts text from multimodal array content' do
      content = [
        { type: 'text', text: 'First part' },
        { type: 'image_url', image_url: { url: 'image.jpg' } },
        { type: 'text', text: 'Second part' }
      ]

      result = service.send(:extract_text_from_content, content)

      expect(result).to eq('First part Second part')
    end
  end

  describe '#dynamic_trace_attributes' do
    subject(:service) { described_class.new(assistant: assistant, conversation: conversation) }

    it 'adds serialized trace input attributes when present in context' do
      context = {
        state: {
          account_id: account.id,
          assistant_id: assistant.id,
          conversation: { id: conversation.id, display_id: conversation.display_id }
        },
        captain_v2_trace_input: '[{"role":"user","content":[{"type":"image_url","image_url":{"url":"https://example.com/image.jpg"}}]}]'
      }
      context_wrapper = Struct.new(:context).new(context)

      attributes = service.send(:dynamic_trace_attributes, context_wrapper)

      expect(attributes['langfuse.trace.input']).to include('image_url')
      expect(attributes['langfuse.observation.input']).to include('image_url')
      expect(attributes['langfuse.user.id']).to eq(account.id.to_s)
    end
  end

  describe '#run_payload knowledge pre-fetch' do
    let(:prefetcher) { instance_double(Captain::KnowledgePrefetcher) }
    let(:history_with_image) do
      [{ role: 'user',
         content: [{ type: 'text', text: 'What does this error mean?' },
                   { type: 'image_url', image_url: { url: 'https://example.com/error.png' } }] }]
    end

    before do
      allow(Captain::KnowledgePrefetcher).to receive(:new).with(assistant).and_return(prefetcher)
      allow(prefetcher).to receive(:attach) { |text| "KB\n#{text}" }
    end

    it 'attaches the pre-fetched FAQs to the user message, never to the system prompt state' do
      service = described_class.new(assistant: assistant, conversation: conversation)

      message, context = service.send(:run_payload, message_history)

      expect(message).to eq("KB\nI need help with my account")
      expect(context[:state]).not_to have_key(:knowledge)
    end

    it 'keeps image attachments while enriching only the text of a multimodal message' do
      service = described_class.new(assistant: assistant, conversation: conversation)

      message, = service.send(:run_payload, history_with_image)

      expect(message).to be_a(RubyLLM::Content)
      expect(message.text).to start_with("KB\n")
      expect(message.attachments.size).to eq(1)
    end

    it 'skips the pre-fetch when there is no conversation (playground/copilot)' do
      service = described_class.new(assistant: assistant, conversation: nil)

      message, = service.send(:run_payload, message_history)

      expect(message).to eq('I need help with my account')
      expect(Captain::KnowledgePrefetcher).not_to have_received(:new)
    end
  end

  describe '#build_state' do
    subject(:service) { described_class.new(assistant: assistant, conversation: conversation) }

    it 'builds state with assistant and account information' do
      state = service.send(:build_state)

      expect(state).to include(
        account_id: account.id,
        assistant_id: assistant.id,
        assistant_config: assistant.config
      )
    end

    it 'includes conversation attributes when conversation is present' do
      state = service.send(:build_state)

      expect(state[:conversation]).to include(
        id: conversation.id,
        inbox_id: inbox.id,
        contact_id: contact.id,
        status: conversation.status
      )
      expect(state[:channel_type]).to eq(inbox.channel_type)
    end

    it 'includes contact inbox attributes when conversation is present' do
      state = service.send(:build_state)

      expect(state[:contact_inbox]).to include(
        id: conversation.contact_inbox.id,
        hmac_verified: conversation.contact_inbox.hmac_verified
      )
    end

    it 'always includes contact attributes in state for tool access' do
      state = service.send(:build_state)

      expect(state[:contact]).to include(
        id: contact.id,
        name: contact.name,
        email: contact.email
      )
    end

    it 'does not include campaign when conversation has no campaign' do
      state = service.send(:build_state)

      expect(state).not_to have_key(:campaign)
    end

    context 'when conversation has a campaign' do
      let(:campaign) { create(:campaign, account: account, title: 'Summer Sale', message: 'Check out our deals!', description: 'Seasonal promo') }
      let(:conversation) { create(:conversation, account: account, inbox: inbox, contact: contact, campaign: campaign) }

      it 'includes campaign attributes in state' do
        state = service.send(:build_state)

        expect(state[:campaign]).to include(
          id: campaign.id,
          title: 'Summer Sale',
          message: 'Check out our deals!',
          description: 'Seasonal promo'
        )
      end

      it 'only includes attributes defined in CAMPAIGN_STATE_ATTRIBUTES' do
        state = service.send(:build_state)

        expect(state[:campaign].keys).to match_array(described_class::CAMPAIGN_STATE_ATTRIBUTES)
      end
    end

    context 'when conversation is nil' do
      subject(:service) { described_class.new(assistant: assistant, conversation: nil) }

      it 'builds state without conversation and contact' do
        state = service.send(:build_state)

        expect(state).to include(
          account_id: account.id,
          assistant_id: assistant.id,
          assistant_config: assistant.config
        )
        expect(state).not_to have_key(:conversation)
        expect(state).not_to have_key(:contact)
        expect(state).not_to have_key(:campaign)
      end
    end
  end

  describe '#add_usage_metadata_callback' do
    it 'sets credit_used=false when handoff tool is used' do
      service = described_class.new(assistant: assistant, conversation: conversation)
      runner = instance_double(Agents::AgentRunner)
      tool_complete_callback = nil
      run_complete_callback = nil
      span_class = Class.new do
        def set_attribute(*); end
      end
      root_span = instance_double(span_class)
      context_wrapper = Struct.new(:context).new({ __otel_tracing: { root_span: root_span } })

      allow(ChatwootApp).to receive(:otel_enabled?).and_return(true)
      allow(runner).to receive(:on_tool_complete) do |&block|
        tool_complete_callback = block
        runner
      end
      allow(runner).to receive(:on_run_complete) do |&block|
        run_complete_callback = block
        runner
      end

      service.send(:add_usage_metadata_callback, runner)

      tool_complete_callback.call(Captain::Tools::HandoffTool.new(assistant).name, 'ok', context_wrapper)

      expect(root_span).to receive(:set_attribute).with('langfuse.trace.metadata.credit_used', 'false')
      run_complete_callback.call('assistant', nil, context_wrapper)
    end

    it 'registers handoff tracking callback when OTEL is disabled' do
      service = described_class.new(assistant: assistant, conversation: conversation)
      runner = instance_double(Agents::AgentRunner)
      tool_complete_callback = nil

      allow(ChatwootApp).to receive(:otel_enabled?).and_return(false)
      allow(runner).to receive(:on_tool_complete) do |&block|
        tool_complete_callback = block
        runner
      end

      service.send(:add_usage_metadata_callback, runner)

      context_wrapper = Struct.new(:context).new({})

      expect(tool_complete_callback).not_to be_nil
      tool_complete_callback.call(Captain::Tools::HandoffTool.new(assistant).name, 'ok', context_wrapper)

      expect(context_wrapper.context[:captain_v2_handoff_tool_called]).to be true
    end

    it 'does not mark a failed handoff as executed' do
      service = described_class.new(assistant: assistant, conversation: conversation)
      runner = instance_double(Agents::AgentRunner)
      tool_complete_callback = nil

      allow(ChatwootApp).to receive(:otel_enabled?).and_return(false)
      allow(runner).to receive(:on_tool_complete) do |&block|
        tool_complete_callback = block
        runner
      end

      service.send(:add_usage_metadata_callback, runner)
      context_wrapper = Struct.new(:context).new({})
      tool_complete_callback.call(Captain::Tools::HandoffTool.new(assistant).name, 'Failed to handoff conversation', context_wrapper)

      expect(context_wrapper.context[:captain_v2_handoff_tool_called]).to be_nil
      expect(context_wrapper.context[:captain_v2_handoff_tool_failed]).to be true
    end

    it 'does not register OTEL run callback when OTEL is disabled' do
      service = described_class.new(assistant: assistant, conversation: conversation)
      runner = instance_double(Agents::AgentRunner)

      allow(ChatwootApp).to receive(:otel_enabled?).and_return(false)
      allow(runner).to receive(:on_tool_complete).and_return(runner)
      expect(runner).not_to receive(:on_run_complete)

      service.send(:add_usage_metadata_callback, runner)
    end

    it 'counts content tool calls but ignores housekeeping and handoff tools' do
      service = described_class.new(assistant: assistant, conversation: conversation)
      runner = instance_double(Agents::AgentRunner)
      tool_complete_callback = nil

      allow(ChatwootApp).to receive(:otel_enabled?).and_return(false)
      allow(runner).to receive(:on_tool_complete) do |&block|
        tool_complete_callback = block
        runner
      end

      service.send(:add_usage_metadata_callback, runner)

      context_wrapper = Struct.new(:context).new({})
      tool_complete_callback.call('search_documentation', 'ok', context_wrapper)
      tool_complete_callback.call('faq_lookup', 'ok', context_wrapper)
      tool_complete_callback.call('add_label_to_conversation', 'ok', context_wrapper)
      tool_complete_callback.call('add_contact_note', 'ok', context_wrapper)
      tool_complete_callback.call('handoff_to_billing', 'ok', context_wrapper)
      tool_complete_callback.call(Captain::Tools::HandoffTool.new(assistant).name, 'ok', context_wrapper)

      expect(context_wrapper.context[:captain_v2_content_tool_calls]).to eq(2)
    end

    it 'sets credit_used=true when handoff tool is not used' do
      service = described_class.new(assistant: assistant, conversation: conversation)
      runner = instance_double(Agents::AgentRunner)
      run_complete_callback = nil
      span_class = Class.new do
        def set_attribute(*); end
      end
      root_span = instance_double(span_class)
      context_wrapper = Struct.new(:context).new({ __otel_tracing: { root_span: root_span } })

      allow(ChatwootApp).to receive(:otel_enabled?).and_return(true)
      allow(runner).to receive(:on_tool_complete).and_return(runner)
      allow(runner).to receive(:on_run_complete) do |&block|
        run_complete_callback = block
        runner
      end

      service.send(:add_usage_metadata_callback, runner)

      expect(root_span).to receive(:set_attribute).with('langfuse.trace.metadata.credit_used', 'true')
      run_complete_callback.call('assistant', nil, context_wrapper)
    end
  end

  describe '#add_usage_tracking_callback' do
    # Unlike V1 (Captain::ChatHelperAdaki), V2 never called
    # Adaki::CaptainUsageTracker at all — every response was invisible to
    # Adaki's usage dashboard. See docs/adaki/captain-remediacion.md §Fase 4
    # (C10).
    it 'accumulates tokens across every LLM call the chat makes, not just the last one' do
      service = described_class.new(assistant: assistant, conversation: conversation)
      runner = instance_double(Agents::AgentRunner)
      chat_created_callback = nil

      allow(runner).to receive(:on_chat_created) do |&block|
        chat_created_callback = block
        runner
      end

      service.send(:add_usage_tracking_callback, runner)

      chat = instance_double(RubyLLM::Chat)
      end_message_callback = nil
      allow(chat).to receive(:on_end_message) do |&block|
        end_message_callback = block
      end
      context_wrapper = Struct.new(:context).new({})

      chat_created_callback.call(chat, 'Assistant', 'gpt-4.1-mini', context_wrapper)
      end_message_callback.call(instance_double(RubyLLM::Message, input_tokens: 10, output_tokens: 5))
      end_message_callback.call(instance_double(RubyLLM::Message, input_tokens: 20, output_tokens: 8))

      expect(context_wrapper.context[:captain_v2_usage]).to eq({ input: 30, output: 13 })
    end
  end

  describe '#record_adaki_usage!' do
    it 'records the accumulated usage from the final result context' do
      service = described_class.new(assistant: assistant, conversation: conversation)
      result = instance_double(Agents::RunResult, context: { captain_v2_usage: { input: 30, output: 13 } })

      expect(Adaki::CaptainUsageTracker).to receive(:record!).with(
        hash_including(account: account, feature: 'assistant', input_tokens: 30, output_tokens: 13, assistant_id: assistant.id)
      )

      service.send(:record_adaki_usage!, result)
    end

    it 'records zero usage instead of raising when the run never reached a chat (e.g. failed before any LLM call)' do
      service = described_class.new(assistant: assistant, conversation: conversation)
      result = instance_double(Agents::RunResult, context: nil)

      expect(Adaki::CaptainUsageTracker).to receive(:record!).with(
        hash_including(input_tokens: 0, output_tokens: 0)
      )

      service.send(:record_adaki_usage!, result)
    end
  end

  describe 'constants' do
    it 'defines conversation state attributes' do
      expect(described_class::CONVERSATION_STATE_ATTRIBUTES).to include(
        :id, :display_id, :inbox_id, :contact_id, :status, :priority
      )
    end

    it 'defines contact state attributes' do
      expect(described_class::CONTACT_STATE_ATTRIBUTES).to include(
        :id, :name, :email, :phone_number, :identifier, :contact_type
      )
    end

    it 'defines campaign state attributes' do
      expect(described_class::CAMPAIGN_STATE_ATTRIBUTES).to include(
        :id, :title, :message, :campaign_type, :description
      )
    end
  end
end
