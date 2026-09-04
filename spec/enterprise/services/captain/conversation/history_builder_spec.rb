require 'rails_helper'

RSpec.describe Captain::Conversation::HistoryBuilder do
  let(:account) { create(:account) }
  let(:inbox) { create(:inbox, account: account) }
  let(:assistant) { create(:captain_assistant, account: account) }
  let(:conversation) { create(:conversation, inbox: inbox, account: account) }

  describe '#call' do
    it 'maps an incoming message to role user' do
      create(:message, conversation: conversation, content: 'Hola', message_type: :incoming)

      history = described_class.new(conversation: conversation, assistant: assistant).call

      expect(history).to eq([{ content: 'Hola', role: 'user' }])
    end

    it "keeps the assistant's own reply as role assistant, unprefixed" do
      create(:message, conversation: conversation, content: 'Hola', message_type: :incoming)
      create(:message, conversation: conversation, content: 'Respuesta', message_type: :outgoing,
                       sender: assistant, account: account)

      history = described_class.new(conversation: conversation, assistant: assistant).call

      expect(history.last).to eq({ content: 'Respuesta', role: 'assistant' })
    end

    it 'keeps the Captain sub-agent tag (agent_name) on the bot reply, for V2 multi-agent handoffs' do
      create(:message, conversation: conversation, content: 'Hola', message_type: :incoming)
      create(:message, conversation: conversation, content: 'Respuesta', message_type: :outgoing,
                       sender: assistant, account: account, additional_attributes: { 'agent_name' => 'ventas' })

      history = described_class.new(conversation: conversation, assistant: assistant).call

      expect(history.last).to eq({ content: 'Respuesta', role: 'assistant', agent_name: 'ventas' })
    end

    it 'drops the sub-agent tag once the bot reply is older than AGENT_STICKINESS_WINDOW, so the orchestrator takes the next turn' do
      create(:message, conversation: conversation, content: 'Hola', message_type: :incoming, created_at: 3.hours.ago)
      create(:message, conversation: conversation, content: 'Respuesta', message_type: :outgoing,
                       sender: assistant, account: account, additional_attributes: { 'agent_name' => 'ventas' },
                       created_at: (described_class::AGENT_STICKINESS_WINDOW + 1.minute).ago)
      create(:message, conversation: conversation, content: 'Hola otra vez', message_type: :incoming)

      history = described_class.new(conversation: conversation, assistant: assistant).call

      expect(history.find { |msg| msg[:role] == 'assistant' }).to eq({ content: 'Respuesta', role: 'assistant' })
    end

    it 'keeps the sub-agent tag while the bot reply is still within AGENT_STICKINESS_WINDOW' do
      create(:message, conversation: conversation, content: 'Hola', message_type: :incoming, created_at: 3.hours.ago)
      create(:message, conversation: conversation, content: 'Respuesta', message_type: :outgoing,
                       sender: assistant, account: account, additional_attributes: { 'agent_name' => 'ventas' },
                       created_at: (described_class::AGENT_STICKINESS_WINDOW - 1.minute).ago)
      create(:message, conversation: conversation, content: 'Hola otra vez', message_type: :incoming)

      history = described_class.new(conversation: conversation, assistant: assistant).call

      expect(history.find { |msg| msg[:role] == 'assistant' }[:agent_name]).to eq('ventas')
    end

    it "marks a human agent's reply as user (never assistant), prefixed so the LLM knows it isn't the customer either" do
      agent = create(:user, account: account)
      create(:message, conversation: conversation, content: 'Hola', message_type: :incoming)
      create(:message, conversation: conversation, content: 'Nota interna del agente', message_type: :outgoing,
                       sender: agent, account: account)

      history = described_class.new(conversation: conversation, assistant: assistant).call

      expect(history.last).to eq({
                                   content: "#{described_class::HUMAN_AGENT_MESSAGE_PREFIX}Nota interna del agente",
                                   role: 'user'
                                 })
    end

    it 'does not tag a human agent reply with agent_name' do
      agent = create(:user, account: account)
      create(:message, conversation: conversation, content: 'Nota', message_type: :outgoing,
                       sender: agent, account: account, additional_attributes: { 'agent_name' => 'should-be-ignored' })

      history = described_class.new(conversation: conversation, assistant: assistant).call

      expect(history.last).not_to have_key(:agent_name)
    end

    it 'excludes private notes' do
      create(:message, conversation: conversation, content: 'private note', message_type: :outgoing,
                       private: true, sender: assistant, account: account)

      expect(described_class.new(conversation: conversation, assistant: assistant).call).to eq([])
    end

    context 'with a configured history window' do
      before { assistant.update!(config: assistant.config.merge('history_window_messages' => 2)) }

      it 'only includes the most recent N messages, in chronological order' do
        create(:message, conversation: conversation, content: 'first', message_type: :incoming)
        create(:message, conversation: conversation, content: 'second', message_type: :incoming)
        create(:message, conversation: conversation, content: 'third', message_type: :incoming)

        history = described_class.new(conversation: conversation, assistant: assistant).call

        expect(history).to eq([
                                { content: 'second', role: 'user' },
                                { content: 'third', role: 'user' }
                              ])
      end
    end

    context 'without a configured history window' do
      it 'falls back to Captain::Assistant::DEFAULT_HISTORY_WINDOW_MESSAGES' do
        expect(assistant.history_window_messages_value).to eq(Captain::Assistant::DEFAULT_HISTORY_WINDOW_MESSAGES)
      end
    end

    context 'when a message is longer than MAX_MESSAGE_LENGTH' do
      it 'truncates the text before sending it to the LLM' do
        overlong = 'a' * (described_class::MAX_MESSAGE_LENGTH + 500)
        create(:message, conversation: conversation, content: overlong, message_type: :incoming)

        history = described_class.new(conversation: conversation, assistant: assistant).call

        expect(history.first[:content].length).to eq(described_class::MAX_MESSAGE_LENGTH + 1) # +1 for the truncation marker
        expect(history.first[:content]).to start_with('a' * described_class::MAX_MESSAGE_LENGTH)
      end
    end

    context 'with multimodal content (text + image)' do
      it 'truncates/prefixes only the text part, leaving image parts untouched' do
        message = create(:message, conversation: conversation, content: 'look at this', message_type: :incoming)
        message.attachments.create!(account: account, file_type: :image, external_url: 'https://example.com/x.jpg')

        history = described_class.new(conversation: conversation, assistant: assistant).call
        content = history.first[:content]

        expect(content).to be_an(Array)
        expect(content.find { |part| part[:type] == 'text' }[:text]).to eq('look at this')
        expect(content.find { |part| part[:type] == 'image_url' }[:image_url][:url]).to eq('https://example.com/x.jpg')
      end
    end
  end
end
