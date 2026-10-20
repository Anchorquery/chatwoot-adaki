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

    it 'lets the bot resume after an assigned conversation has been idle for the window' do
      conversation.update!(assignee: agent)

      travel_to((assistant.human_takeover_window_minutes_value + 1).minutes.from_now) do
        expect(described_class.new(conversation: conversation.reload).human_takeover?).to be(false)
      end
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

    # An agent who has been handling an open conversation for days must not
    # lose it because the customer took longer than the minute window to
    # answer. Off by default (0 days): nothing changes until configured.
    context 'with an active human thread (human_takeover_active_thread_days)' do
      let(:captain_inbox) { CaptainInbox.find_by!(inbox: inbox) }

      def set_assistant_days(days, mode: 'after_window')
        assistant.update!(config: assistant.config.merge('human_takeover_mode' => mode,
                                                         'human_takeover_window_minutes' => 15,
                                                         'human_takeover_active_thread_days' => days))
      end

      # Assigning stamps captain_takeover_at = now, so the assignment itself
      # has to happen in the past for the minute window to be over.
      def assign_and_reply(ago:, assign: true, private_note: false)
        travel_to(ago.ago) do
          conversation.update!(assignee: agent) if assign
          create(:message, conversation: conversation, message_type: :outgoing, sender: agent, account: account,
                           content: 'Hola, soy Ana', private: private_note)
        end
      end

      def fresh_evaluator
        described_class.new(conversation: conversation.reload)
      end

      it 'is disabled by default: the minute window alone decides' do
        assign_and_reply(ago: 2.days)

        expect(fresh_evaluator.human_takeover?).to be(false)
      end

      it 'keeps the thread human while the assignee replied within the configured days' do
        set_assistant_days(7)
        assign_and_reply(ago: 2.days)

        expect(fresh_evaluator.human_takeover?).to be(true)
      end

      it 'lets the bot resume once the last human reply is older than the configured days' do
        set_assistant_days(7)
        assign_and_reply(ago: 8.days)

        expect(fresh_evaluator.human_takeover?).to be(false)
      end

      it 'falls back to the minute window when nobody is assigned' do
        set_assistant_days(7)
        assign_and_reply(ago: 2.days, assign: false)

        expect(fresh_evaluator.human_takeover?).to be(false)
      end

      it 'falls back to the minute window when the assignee only wrote private notes' do
        set_assistant_days(7)
        assign_and_reply(ago: 2.days, private_note: true)

        expect(fresh_evaluator.human_takeover?).to be(false)
      end

      it 'falls back to the minute window when the conversation is not open' do
        set_assistant_days(7)
        assign_and_reply(ago: 2.days)
        conversation.update!(status: :pending)

        expect(fresh_evaluator.human_takeover?).to be(false)
      end

      it 'stops holding the thread once the conversation was resolved after the reply' do
        set_assistant_days(7)
        assign_and_reply(ago: 2.days)
        create(:reporting_event, name: 'conversation_resolved', account: account, inbox: inbox, conversation: conversation,
                                 user: agent, created_at: 1.day.ago)

        expect(fresh_evaluator.human_takeover?).to be(false)
      end

      it 'ignores a resolution that happened before the reply' do
        set_assistant_days(7)
        create(:reporting_event, name: 'conversation_resolved', account: account, inbox: inbox, conversation: conversation,
                                 user: agent, created_at: 3.days.ago)
        assign_and_reply(ago: 2.days)

        expect(fresh_evaluator.human_takeover?).to be(true)
      end

      it 'does not apply in always mode' do
        set_assistant_days(7, mode: 'always')
        assign_and_reply(ago: 2.days)

        expect(fresh_evaluator.human_takeover?).to be(false)
      end

      it 'changes nothing in never mode (human already owns the thread)' do
        set_assistant_days(7, mode: 'never')
        assign_and_reply(ago: 20.days)

        expect(fresh_evaluator.human_takeover?).to be(true)
      end

      it 'still honours the pending Captain handoff marker first' do
        set_assistant_days(7)
        allow(Rails.configuration.dispatcher).to receive(:dispatch)
        conversation.bot_handoff!

        expect(fresh_evaluator.human_takeover?).to be(true)
      end

      it 'lets an inbox override of 0 switch the rule off for that inbox' do
        set_assistant_days(7)
        captain_inbox.update!(settings: { 'human_takeover_active_thread_days' => 0 })
        assign_and_reply(ago: 2.days)

        expect(fresh_evaluator.human_takeover?).to be(false)
      end

      it 'lets an inbox override switch the rule on when the assistant has it off' do
        set_assistant_days(0)
        captain_inbox.update!(settings: { 'human_takeover_active_thread_days' => '7' })
        assign_and_reply(ago: 2.days)

        expect(fresh_evaluator.human_takeover?).to be(true)
      end
    end
  end
end
