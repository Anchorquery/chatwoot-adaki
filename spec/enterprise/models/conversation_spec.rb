require 'rails_helper'

RSpec.describe Conversation, type: :model do
  describe 'associations' do
    it { is_expected.to belong_to(:sla_policy).optional }
  end

  describe '#bot_handoff! on a conversation that is already open (Adaki: Captain answers open conversations)' do
    let(:account) { create(:account) }
    let(:inbox) { create(:inbox, account: account, enable_auto_assignment: true) }
    let(:agent) { create(:user, account: account) }
    let(:conversation) { create(:conversation, account: account, inbox: inbox, status: :open) }

    before do
      create(:inbox_member, inbox: inbox, user: agent)
      allow(OnlineStatusTracker).to receive(:get_available_users).and_return({ agent.id.to_s => 'online' })
      allow(Rails.configuration.dispatcher).to receive(:dispatch)
    end

    it 'stamps captain_handoff_at so HumanTakeoverEvaluator can tell the bot stepped aside' do
      freeze_time do
        conversation.bot_handoff!

        expect(conversation.reload.captain_handoff_at).to be_within(1.second).of(Time.current)
      end
    end

    it 'still dispatches CONVERSATION_BOT_HANDOFF' do
      expect(Rails.configuration.dispatcher).to receive(:dispatch)
        .with(described_class::CONVERSATION_BOT_HANDOFF, anything, hash_including(conversation: conversation))

      conversation.bot_handoff!
    end

    it 'enqueues the inbox auto-assignment (assignment V2) even though the status did not change' do
      conversation # created up front: creating it open enqueues an assignment of its own
      expect(AutoAssignment::AssignmentJob).to receive(:enqueue_for_inbox).with(inbox.id).once

      conversation.bot_handoff!
    end

    it 'assigns an online inbox member synchronously on the legacy assignment path' do
      account.disable_features('assignment_v2')

      conversation.bot_handoff!

      expect(conversation.reload.assignee).to eq(agent)
    end

    it 'does not assign when the inbox has auto-assignment disabled' do
      inbox.update!(enable_auto_assignment: false)

      conversation.bot_handoff!

      expect(conversation.reload.assignee).to be_nil
    end

    it 'keeps an existing assignee' do
      other = create(:user, account: account)
      create(:inbox_member, inbox: inbox, user: other)
      conversation.update!(assignee: other)

      conversation.bot_handoff!

      expect(conversation.reload.assignee).to eq(other)
    end

    context 'with a Captain handoff team configured for the inbox' do
      let(:assistant) { create(:captain_assistant, account: account) }
      let(:team) { create(:team, account: account) }
      let(:team_agent) { create(:user, account: account) }

      before do
        create(:captain_inbox, inbox: inbox, captain_assistant: assistant, settings: { 'handoff_team_id' => team.id })
        create(:inbox_member, inbox: inbox, user: team_agent)
        create(:team_member, team: team, user: team_agent)
        allow(OnlineStatusTracker).to receive(:get_available_users)
          .and_return({ agent.id.to_s => 'online', team_agent.id.to_s => 'online' })
      end

      it 'tags the conversation with that team' do
        conversation.bot_handoff!

        expect(conversation.reload.team).to eq(team)
      end

      it 'assigns only among that team (legacy assignment path)' do
        account.disable_features('assignment_v2')

        conversation.bot_handoff!

        expect(conversation.reload.assignee).to eq(team_agent)
      end

      it 'never overwrites a team an agent already chose' do
        other_team = create(:team, account: account)
        conversation.update!(team: other_team)

        conversation.bot_handoff!

        expect(conversation.reload.team).to eq(other_team)
      end
    end

    it 'stamps the marker on the pending → open path too' do
      pending = create(:conversation, account: account, inbox: inbox, status: :pending)

      pending.bot_handoff!

      expect(pending.reload).to be_open
      expect(pending.captain_handoff_at).to be_present
    end
  end

  describe 'SLA policy updates' do
    let(:conversation) { create(:conversation) }
    let!(:sla_policy) { create(:sla_policy, account: conversation.account) }

    before do
      stub_request(:get, %r{\Ahttps://www\.gravatar\.com.*}).to_return(status: 404)
      stub_request(:get, %r{\Ahttps://www\.google\.com/s2/favicons.*}).to_return(status: 404)
    end

    it 'generates an activity message when the SLA policy is updated' do
      conversation.update!(sla_policy_id: sla_policy.id)

      perform_enqueued_jobs

      activity_message = conversation.messages.where(message_type: 'activity').last

      expect(activity_message).not_to be_nil
      expect(activity_message.message_type).to eq('activity')
      expect(activity_message.content).to include('added SLA policy')
    end

    # TODO: Reenable this when we let the SLA policy be removed from a conversation
    # it 'generates an activity message when the SLA policy is removed' do
    #   conversation.update!(sla_policy_id: sla_policy.id)
    #   conversation.update!(sla_policy_id: nil)

    #   perform_enqueued_jobs

    #   activity_message = conversation.messages.where(message_type: 'activity').last

    #   expect(activity_message).not_to be_nil
    #   expect(activity_message.message_type).to eq('activity')
    #   expect(activity_message.content).to include('removed SLA policy')
    # end
  end

  describe 'sla_policy' do
    let(:account) { create(:account) }
    let(:conversation) { create(:conversation, account: account) }
    let(:sla_policy) { create(:sla_policy, account: account) }
    let(:different_account_sla_policy) { create(:sla_policy) }

    context 'when sla_policy is getting updated' do
      it 'throws error if sla policy belongs to different account' do
        conversation.sla_policy = different_account_sla_policy
        expect(conversation.valid?).to be false
        expect(conversation.errors[:sla_policy]).to include('sla policy account mismatch')
      end

      it 'creates applied sla record if sla policy is present' do
        conversation.sla_policy = sla_policy
        conversation.save!
        expect(conversation.applied_sla.sla_policy_id).to eq(sla_policy.id)
      end
    end

    context 'when conversation already has a different sla' do
      before do
        conversation.update(sla_policy: create(:sla_policy, account: account))
      end

      it 'throws error if trying to assing a different sla' do
        conversation.sla_policy = sla_policy
        expect(conversation.valid?).to be false
        expect(conversation.errors[:sla_policy]).to eq(['conversation already has a different sla'])
      end

      it 'throws error if trying to set sla to nil' do
        conversation.sla_policy = nil
        expect(conversation.valid?).to be false
        expect(conversation.errors[:sla_policy]).to eq(['cannot remove sla policy from conversation'])
      end
    end
  end

  describe 'assignment capacity limits' do
    describe 'team assignment with inbox auto-assignment disabled' do
      let(:account) { create(:account) }
      let(:inbox) { create(:inbox, account: account, enable_auto_assignment: false, auto_assignment_config: { max_assignment_limit: 1 }) }
      let(:team) { create(:team, account: account, allow_auto_assign: true) }
      let!(:agent1) { create(:user, account: account, role: :agent, auto_offline: false) }
      let!(:agent2) { create(:user, account: account, role: :agent, auto_offline: false) }

      before do
        create(:inbox_member, inbox: inbox, user: agent1)
        create(:inbox_member, inbox: inbox, user: agent2)
        create(:team_member, team: team, user: agent1)
        create(:team_member, team: team, user: agent2)
        # Both agents are over the limit (simulate by assigning open conversations)
        create_list(:conversation, 2, inbox: inbox, assignee: agent1, status: :open)
        create_list(:conversation, 2, inbox: inbox, assignee: agent2, status: :open)
      end

      it 'does not enforce max_assignment_limit for team assignment when inbox auto-assignment is disabled' do
        conversation = create(:conversation, inbox: inbox, account: account, assignee: nil, status: :open)

        # Assign to team to trigger the assignment logic
        conversation.update!(team: team)

        # Should assign to a team member even if they are over the limit
        expect(conversation.reload.assignee).to be_present
        expect([agent1, agent2]).to include(conversation.reload.assignee)
      end
    end
  end
end
