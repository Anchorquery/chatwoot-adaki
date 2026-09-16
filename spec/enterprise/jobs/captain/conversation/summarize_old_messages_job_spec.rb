require 'rails_helper'

RSpec.describe Captain::Conversation::SummarizeOldMessagesJob, type: :job do
  let(:account) { create(:account) }
  let(:inbox) { create(:inbox, account: account) }
  let(:conversation) { create(:conversation, account: account, inbox: inbox) }
  let(:mock_summarizer) { instance_double(Captain::Llm::ConversationSummarizerService) }

  before do
    allow(Captain::Llm::ConversationSummarizerService).to receive(:new).and_return(mock_summarizer)
  end

  describe '#perform' do
    it "summarizes the oldest `old_count` messages and stores the result on the conversation's additional_attributes" do
      old1 = create(:message, conversation: conversation, content: 'first', message_type: :incoming, created_at: 3.days.ago)
      old2 = create(:message, conversation: conversation, content: 'second', message_type: :incoming, created_at: 2.days.ago)
      create(:message, conversation: conversation, content: 'recent', message_type: :incoming, created_at: 1.minute.ago)

      expect(Captain::Llm::ConversationSummarizerService).to receive(:new).with(
        account: account, conversation_display_id: conversation.display_id, messages: [old1, old2]
      ).and_return(mock_summarizer)
      allow(mock_summarizer).to receive(:perform).and_return(message: 'El cliente preguntó dos veces por el precio.')

      described_class.perform_now(conversation, 2)

      conversation.reload
      expect(conversation.additional_attributes['captain_summary']).to eq('El cliente preguntó dos veces por el precio.')
      expect(conversation.additional_attributes['captain_summary_covers']).to eq(2)
    end

    it 'excludes private notes from what gets summarized' do
      create(:message, conversation: conversation, content: 'private', message_type: :outgoing, private: true, created_at: 2.days.ago)
      real = create(:message, conversation: conversation, content: 'real', message_type: :incoming, created_at: 1.day.ago)

      expect(Captain::Llm::ConversationSummarizerService).to receive(:new).with(
        hash_including(messages: [real])
      ).and_return(mock_summarizer)
      allow(mock_summarizer).to receive(:perform).and_return(message: 'resumen')

      described_class.perform_now(conversation, 1)
    end

    it 'does nothing when there are no messages to summarize yet' do
      expect(Captain::Llm::ConversationSummarizerService).not_to receive(:new)

      described_class.perform_now(conversation, 5)
    end

    it 'does not update the conversation when the summarizer returns an error' do
      create(:message, conversation: conversation, content: 'first', message_type: :incoming)
      allow(mock_summarizer).to receive(:perform).and_return(error: 'boom')

      described_class.perform_now(conversation, 1)

      expect(conversation.reload.additional_attributes['captain_summary']).to be_nil
    end

    it 'does not update the conversation when the summarizer returns a blank message' do
      create(:message, conversation: conversation, content: 'first', message_type: :incoming)
      allow(mock_summarizer).to receive(:perform).and_return(message: nil)

      described_class.perform_now(conversation, 1)

      expect(conversation.reload.additional_attributes['captain_summary']).to be_nil
    end

    it 'never raises, even if the summarizer itself blows up' do
      create(:message, conversation: conversation, content: 'first', message_type: :incoming)
      allow(mock_summarizer).to receive(:perform).and_raise(StandardError, 'provider down')

      expect { described_class.perform_now(conversation, 1) }.not_to raise_error
    end
  end
end
