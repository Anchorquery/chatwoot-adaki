require 'rails_helper'

RSpec.describe Captain::Llm::AssistantChatService do
  let(:account) { create(:account) }
  let(:assistant) { create(:captain_assistant, account: account) }
  let(:conversation) { create(:conversation, account: account) }

  let(:mock_chat) { instance_double(RubyLLM::Chat) }
  let(:mock_response) do
    instance_double(
      RubyLLM::Message,
      content: '{"response": "I can see the image shows a pricing table", "reasoning": "Analyzed the image"}'
    )
  end

  before do
    create(:installation_config, name: 'CAPTAIN_OPEN_AI_API_KEY', value: 'test-key')

    allow(RubyLLM).to receive(:chat).and_return(mock_chat)
    allow(mock_chat).to receive(:with_temperature).and_return(mock_chat)
    allow(mock_chat).to receive(:with_params).and_return(mock_chat)
    allow(mock_chat).to receive(:with_tool).and_return(mock_chat)
    allow(mock_chat).to receive(:with_instructions).and_return(mock_chat)
    allow(mock_chat).to receive(:add_message).and_return(mock_chat)
    allow(mock_chat).to receive(:on_end_message).and_return(mock_chat)
    allow(mock_chat).to receive(:on_tool_call).and_return(mock_chat)
    allow(mock_chat).to receive(:on_tool_result).and_return(mock_chat)
    allow(mock_chat).to receive(:messages).and_return([])
  end

  describe 'Adaki usage tracking' do
    # Captain::ChatResponseHelper#build_response returns the already-parsed
    # JSON reply hash, not the RubyLLM::Message — it never carried usage
    # data, so Adaki::ChatHelperAdaki reading tokens off it always logged
    # 0/0. Captain::ChatHelper#llm_usage now accumulates real tokens from
    # chat.on_end_message instead. See
    # docs/adaki/captain-remediacion.md §Fase 4 (C10).
    #
    # Captain::ChatHelperAdaki only activates via its file's top-level
    # `Captain::ChatHelper.prepend(Captain::ChatHelperAdaki)` — Zeitwerk only
    # runs that when something references the constant. In production
    # eager_load is true, so this always happens at boot; RAILS_ENV=test has
    # eager_load=false (config/environments/test.rb), so nothing loads this
    # file unless referenced explicitly. Confirmed via `Captain::ChatHelper.
    # ancestors` in a real rails runner — without this line the prepend
    # silently never applies in spec runs, and every assertion below would
    # pass or fail for the wrong reason (the real prepended method never ran
    # at all, not that it ran and produced 0/0).
    before { Captain::ChatHelperAdaki }

    it 'records real accumulated token counts, not 0/0' do
      fake_message = instance_double(
        RubyLLM::Message, role: 'assistant', content: 'hi', input_tokens: 42, output_tokens: 17
      )
      allow(mock_chat).to receive(:on_end_message) do |&block|
        block.call(fake_message)
        mock_chat
      end
      allow(mock_chat).to receive(:ask).and_return(mock_response)

      expect(Adaki::CaptainUsageTracker).to receive(:record!).with(
        hash_including(input_tokens: 42, output_tokens: 17)
      )

      described_class.new(assistant: assistant, conversation: conversation)
                     .generate_response(message_history: [{ role: 'user', content: 'Hello' }])
    end

    it 'sums tokens across multiple LLM calls within one response (a tool-call round-trip)' do
      first_message = instance_double(
        RubyLLM::Message, role: 'assistant', content: 'thinking', input_tokens: 10, output_tokens: 5
      )
      second_message = instance_double(
        RubyLLM::Message, role: 'assistant', content: 'hi', input_tokens: 20, output_tokens: 8
      )
      allow(mock_chat).to receive(:on_end_message) do |&block|
        block.call(first_message)
        block.call(second_message)
        mock_chat
      end
      allow(mock_chat).to receive(:ask).and_return(mock_response)

      expect(Adaki::CaptainUsageTracker).to receive(:record!).with(
        hash_including(input_tokens: 30, output_tokens: 13)
      )

      described_class.new(assistant: assistant, conversation: conversation)
                     .generate_response(message_history: [{ role: 'user', content: 'Hello' }])
    end
  end

  describe 'tool compatibility with V1' do
    # Agents::Tool#execute(tool_context, **params) has a required positional
    # arg that RubyLLM::Tool#call never supplies (it calls execute(**args)) —
    # V1's plain RubyLLM::Chat would raise ArgumentError the instant the LLM
    # called one of these tools (FaqLookupTool, HandoffTool, McpTool, and
    # custom HTTP tools all inherit from Agents::Tool). See
    # docs/adaki/captain-remediacion.md §Fase 4 (C5).
    it 'never hands RubyLLM::Chat an Agents::Tool instance' do
      allow(mock_chat).to receive(:ask).and_return(mock_response)
      passed_tools = []
      allow(mock_chat).to receive(:with_tool) do |tool|
        passed_tools << tool
        mock_chat
      end

      described_class.new(assistant: assistant, conversation: conversation)
                     .generate_response(message_history: [{ role: 'user', content: 'Hello' }])

      expect(passed_tools).not_to be_empty
      expect(passed_tools).to all(satisfy { |tool| !tool.is_a?(Agents::Tool) })
    end

    it 'excludes the built-in Agents::Tool-based tools (FaqLookupTool, HandoffTool) specifically' do
      allow(mock_chat).to receive(:ask).and_return(mock_response)
      passed_tools = []
      allow(mock_chat).to receive(:with_tool) do |tool|
        passed_tools << tool
        mock_chat
      end

      described_class.new(assistant: assistant, conversation: conversation)
                     .generate_response(message_history: [{ role: 'user', content: 'Hello' }])

      expect(passed_tools.map(&:class)).not_to include(Captain::Tools::FaqLookupTool, Captain::Tools::HandoffTool)
    end
  end

  describe 'instrumentation metadata' do
    it 'passes channel_type to the agent session instrumentation' do
      service = described_class.new(assistant: assistant, conversation: conversation)

      expect(service).to receive(:instrument_agent_session).with(
        hash_including(metadata: hash_including(channel_type: conversation.inbox.channel_type))
      ).and_yield

      allow(mock_chat).to receive(:ask).and_return(mock_response)
      service.generate_response(message_history: [{ role: 'user', content: 'Hello' }])
    end
  end

  describe 'image analysis' do
    context 'when user sends a message with an image attachment' do
      let(:message_history) do
        [
          {
            role: 'user',
            content: [
              { type: 'text', text: 'What do you see in this image?' },
              { type: 'image_url', image_url: { url: 'https://example.com/screenshot.png' } }
            ]
          }
        ]
      end

      it 'sends the image to the LLM for analysis' do
        expect(mock_chat).to receive(:ask).with(
          'What do you see in this image?',
          with: ['https://example.com/screenshot.png']
        ).and_return(mock_response)

        service = described_class.new(assistant: assistant, conversation: conversation)
        service.generate_response(message_history: message_history)
      end
    end

    context 'when user sends only an image without text' do
      let(:message_history) do
        [
          {
            role: 'user',
            content: [
              { type: 'image_url', image_url: { url: 'https://example.com/photo.jpg' } }
            ]
          }
        ]
      end

      it 'sends the image to the LLM with nil text' do
        expect(mock_chat).to receive(:ask).with(
          nil,
          with: ['https://example.com/photo.jpg']
        ).and_return(mock_response)

        service = described_class.new(assistant: assistant, conversation: conversation)
        service.generate_response(message_history: message_history)
      end
    end

    context 'when user sends a plain text message' do
      let(:message_history) do
        [
          { role: 'user', content: 'Hello, how can you help me?' }
        ]
      end

      it 'sends the text without attachments' do
        expect(mock_chat).to receive(:ask).with('Hello, how can you help me?').and_return(mock_response)

        service = described_class.new(assistant: assistant, conversation: conversation)
        service.generate_response(message_history: message_history)
      end
    end
  end

  describe 'conversation history with images' do
    context 'when previous messages contain images' do
      let(:message_history) do
        [
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
      end

      it 'includes images from conversation history in context' do
        # First historical message should include the image via RubyLLM::Content
        expect(mock_chat).to receive(:add_message) do |args|
          expect(args[:role]).to eq(:user)
          expect(args[:content]).to be_a(RubyLLM::Content)
          expect(args[:content].text).to eq('Here is my error screenshot')
          expect(args[:content].attachments.first.source.to_s).to eq('https://example.com/error.png')
        end.ordered

        # Second historical message is plain text
        expect(mock_chat).to receive(:add_message).with(
          role: :assistant,
          content: 'I see the error. Try restarting.'
        ).ordered

        # Current message asked via chat.ask
        expect(mock_chat).to receive(:ask).with('It still does not work').and_return(mock_response)

        service = described_class.new(assistant: assistant, conversation: conversation)
        service.generate_response(message_history: message_history)
      end
    end
  end

  describe 'contact attributes in system prompt' do
    let(:contact) { create(:contact, account: account, name: 'Diep Bui', email: 'diep@example.com', custom_attributes: { 'plan' => 'pro' }) }
    let(:conversation) { create(:conversation, account: account, contact: contact) }

    context 'when feature_contact_attributes is enabled' do
      before { assistant.update!(config: assistant.config.merge('feature_contact_attributes' => true)) }

      it 'includes contact information in the system prompt' do
        allow(mock_chat).to receive(:ask).and_return(mock_response)

        expect(mock_chat).to receive(:with_instructions).with(a_string_including('[Contact Information]')) do |_instructions|
          mock_chat
        end

        service = described_class.new(assistant: assistant, conversation: conversation)
        service.generate_response(message_history: [{ role: 'user', content: 'Hello' }])
      end

      it 'includes custom attributes in the system prompt' do
        allow(mock_chat).to receive(:ask).and_return(mock_response)

        expect(mock_chat).to receive(:with_instructions).with(a_string_including('plan: pro')) do |_instructions|
          mock_chat
        end

        service = described_class.new(assistant: assistant, conversation: conversation)
        service.generate_response(message_history: [{ role: 'user', content: 'Hello' }])
      end
    end

    context 'when feature_contact_attributes is disabled' do
      it 'does not include contact information in the system prompt' do
        allow(mock_chat).to receive(:ask).and_return(mock_response)

        expect(mock_chat).to receive(:with_instructions).with(satisfy { |s| s.exclude?('[Contact Information]') }) do |_instructions|
          mock_chat
        end

        service = described_class.new(assistant: assistant, conversation: conversation)
        service.generate_response(message_history: [{ role: 'user', content: 'Hello' }])
      end
    end
  end

  describe 'account custom instructions in system prompt' do
    before do
      assistant.update!(config: assistant.config.merge('instructions' => 'if user enters 1112234 suggest handoff'))
    end

    it 'adds custom instructions in a separate delimited section' do
      allow(mock_chat).to receive(:ask).and_return(mock_response)

      expect(mock_chat).to receive(:with_instructions).with(
        a_string_including(
          '<account_custom_instructions>',
          'if user enters 1112234 suggest handoff',
          '</account_custom_instructions>'
        )
      ) do |instructions|
        expect(instructions).not_to include('<custom-instructions>')
        expect(instructions.index('<account_custom_instructions>')).to be < instructions.index('```json')
        mock_chat
      end

      service = described_class.new(assistant: assistant, conversation: conversation)
      service.generate_response(message_history: [{ role: 'user', content: 'Hello' }])
    end
  end
end
