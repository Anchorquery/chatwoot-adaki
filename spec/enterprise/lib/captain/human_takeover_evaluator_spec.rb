require 'rails_helper'

RSpec.describe Captain::HumanTakeoverEvaluator do
  subject(:evaluator) { described_class.new(conversation: conversation) }

  let(:account) { create(:account) }
  let(:inbox) { create(:inbox, account: account) }
  let(:assistant) { create(:captain_assistant, account: account) }
  let(:agent) { create(:user, account: account) }
  let(:conversation) { create(:conversation, account: account, inbox: inbox, status: :open) }

  before do
    create(:captain_inbox, captain_assistant: assistant, inbox: inbox)
    create(:inbox_member, inbox: inbox, user: agent)
  end

  describe '#human_takeover?' do
    it 'lets the bot answer an open conversation nobody has touched' do
      expect(evaluator.human_takeover?).to be(false)
    end

    it 'cedes to a human once an agent is assigned' do
      conversation.update!(assignee: agent)

      expect(evaluator.human_takeover?).to be(true)
    end

    context 'when Captain has handed the conversation off (bot_handoff!)' do
      before do
        allow(Rails.configuration.dispatcher).to receive(:dispatch)
        conversation.bot_handoff!
        conversation.reload
      end

      it 'keeps the bot quiet even though the conversation is open and unassigned' do
        expect(conversation.status).to eq('open')
        expect(conversation.assignee_id).to be_nil
        expect(evaluator.human_takeover?).to be(true)
      end

      it 'keeps the bot quiet regardless of the takeover mode' do
        assistant.update!(config: assistant.config.merge('human_takeover_mode' => 'always'))

        expect(evaluator.human_takeover?).to be(true)
      end

      it 'stops counting the handoff once a human has replied after it (normal mode rules apply again)' do
        assistant.update!(config: assistant.config.merge('human_takeover_mode' => 'always'))
        travel_to(5.minutes.from_now) do
          create(:message, conversation: conversation, message_type: :outgoing, sender: agent, account: account, content: 'Hola, soy Ana')
        end

        expect(described_class.new(conversation: conversation.reload).human_takeover?).to be(false)
      end

      it 'ignores a private note from a human as a "reply"' do
        travel_to(5.minutes.from_now) do
          create(:message, conversation: conversation, message_type: :outgoing, sender: agent, account: account, private: true,
                           content: 'nota')
        end

        expect(described_class.new(conversation: conversation.reload).human_takeover?).to be(true)
      end

      it 'ignores a bot message sent after the handoff (the handoff message itself)' do
        travel_to(1.minute.from_now) do
          create(:message, conversation: conversation, message_type: :outgoing, sender: assistant, account: account,
                           content: 'Te paso con un compañero')
        end

        expect(described_class.new(conversation: conversation.reload).human_takeover?).to be(true)
      end

      it 'stops counting the handoff once the conversation was resolved after it (a reopen starts fresh)' do
        travel_to(1.hour.from_now) do
          create(:reporting_event, name: 'conversation_resolved', account: account, inbox: inbox, conversation: conversation, user: agent)
        end

        expect(described_class.new(conversation: conversation.reload).human_takeover?).to be(false)
      end

      it 'does not count a resolution that happened before the handoff' do
        create(:reporting_event, name: 'conversation_resolved', account: account, inbox: inbox, conversation: conversation, user: agent,
                                 created_at: 1.day.ago)

        expect(described_class.new(conversation: conversation.reload).human_takeover?).to be(true)
      end
    end

    it 'treats a malformed marker as no handoff' do
      conversation.update!(additional_attributes: { 'captain_handoff_at' => 'not a time' })

      expect(evaluator.human_takeover?).to be(false)
    end
  end
end
