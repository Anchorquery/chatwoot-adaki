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

      it 'lets the bot resume after the window when an agent was assigned but never replied' do
        conversation.update!(assignee: agent)

        travel_to((assistant.human_takeover_window_minutes_value + 1).minutes.from_now) do
          expect(described_class.new(conversation: conversation.reload).human_takeover?).to be(false)
        end
      end

      # Otherwise a handoff nobody picked up (no agent online, or nobody
      # collaborating on the inbox) left the customer talking to no one:
      # neither the bot nor a human ever replied again.
      it 'lets the bot resume once the re-engagement window passes with nobody picking it up' do
        travel_to((assistant.human_takeover_window_minutes_value + 1).minutes.from_now) do
          expect(described_class.new(conversation: conversation.reload).human_takeover?).to be(false)
        end
      end

      it 'keeps the bot quiet while that window is still running' do
        travel_to((assistant.human_takeover_window_minutes_value - 1).minutes.from_now) do
          expect(described_class.new(conversation: conversation.reload).human_takeover?).to be(true)
        end
      end

      # A bot-initiated handoff is a temporary ownership marker, not a human
      # takeover preference: even in `never` mode, a handoff nobody picked up
      # releases the bot after the grace window instead of silencing the
      # conversation forever. `never` still applies once a human has replied.
      it 'releases the bot after the grace window in never mode when nobody picked the handoff up' do
        assistant.update!(config: assistant.config.merge('human_takeover_mode' => 'never'))

        travel_to((assistant.human_takeover_window_minutes_value - 1).minutes.from_now) do
          expect(described_class.new(conversation: conversation.reload).human_takeover?).to be(true)
        end

        travel_to((assistant.human_takeover_window_minutes_value + 1).minutes.from_now) do
          expect(described_class.new(conversation: conversation.reload).human_takeover?).to be(false)
        end
      end

      it 'does not silence the bot at all when the mode says it always replies' do
        assistant.update!(config: assistant.config.merge('human_takeover_mode' => 'always'))

        expect(evaluator.human_takeover?).to be(false)
      end

      # Once a human is in the conversation the handoff marker steps aside and
      # the configured mode takes over: the window is then measured from the
      # human's own reply, not from the handoff.
      it 'measures the window from the human reply once someone has answered' do
        travel_to(5.minutes.from_now) do
          create(:message, conversation: conversation, message_type: :outgoing, sender: agent, account: account, content: 'Hola, soy Ana')
        end

        travel_to(10.minutes.from_now) do
          expect(described_class.new(conversation: conversation.reload).human_takeover?).to be(true)
        end

        travel_to((assistant.human_takeover_window_minutes_value + 10).minutes.from_now) do
          expect(described_class.new(conversation: conversation.reload).human_takeover?).to be(false)
        end
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
