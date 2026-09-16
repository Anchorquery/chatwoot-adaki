require 'rails_helper'

RSpec.describe Captain::Llm::ConversationSummarizerService do
  let(:account) { create(:account) }
  let(:inbox) { create(:inbox, account: account) }
  let(:assistant) { create(:captain_assistant, account: account) }
  let(:conversation) { create(:conversation, account: account, inbox: inbox) }
  let(:mock_chat) { instance_double(RubyLLM::Chat) }
  let(:mock_context) { instance_double(RubyLLM::Context, chat: mock_chat) }
  let(:mock_response) { instance_double(RubyLLM::Message, content: 'Resumen.', input_tokens: 50, output_tokens: 10) }

  before do
    create(:installation_config, name: 'CAPTAIN_OPEN_AI_API_KEY', value: 'test-key')
    allow(Llm::Config).to receive(:with_api_key).and_yield(mock_context)
    allow(mock_chat).to receive(:with_instructions)
    allow(mock_chat).to receive(:ask).and_return(mock_response)
    allow(account).to receive(:feature_enabled?).and_call_original
    allow(account).to receive(:feature_enabled?).with('captain_tasks').and_return(true)
  end

  describe '#perform' do
    let(:messages) do
      [
        create(:message, conversation: conversation, content: 'Hola, quiero saber el precio', message_type: :incoming),
        create(:message, conversation: conversation, content: 'Cuesta 20€', message_type: :outgoing, sender: assistant, account: account)
      ]
    end
    let(:service) { described_class.new(account: account, conversation_display_id: conversation.display_id, messages: messages) }

    it 'returns the summary text' do
      result = service.perform

      expect(result[:message]).to eq('Resumen.')
    end

    it 'formats each message with its speaker before sending it to the model' do
      expected = /Customer: Hola, quiero saber el precio\nAssistant: Cuesta 20€/
      expect(mock_chat).to receive(:ask).with(a_string_matching(expected)).and_return(mock_response)

      service.perform
    end

    it "labels a human agent's message as Agent, not Assistant" do
      human_agent = create(:user, account: account)
      human_messages = [
        create(:message, conversation: conversation, content: 'nota', message_type: :outgoing, sender: human_agent, account: account)
      ]

      expect(mock_chat).to receive(:ask).with(a_string_matching(/\AAgent: nota\z/)).and_return(mock_response)

      described_class.new(account: account, conversation_display_id: conversation.display_id, messages: human_messages).perform
    end

    it 'skips messages with blank content instead of sending an empty line' do
      blank_message = build(:message, conversation: conversation, content: nil, message_type: :incoming)
      allow(blank_message).to receive(:content_for_llm).and_return('')

      result = described_class.new(account: account, conversation_display_id: conversation.display_id, messages: [blank_message]).perform

      expect(result).to eq(message: nil)
      expect(mock_chat).not_to have_received(:ask)
    end

    it 'does not count toward the account response quota' do
      allow(account).to receive(:increment_response_usage)

      service.perform

      expect(account).not_to have_received(:increment_response_usage)
    end
  end
end
