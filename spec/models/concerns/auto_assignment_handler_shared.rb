# frozen_string_literal: true

require 'rails_helper'

shared_examples_for 'auto_assignment_handler' do
  describe '#auto assignment' do
    let(:account) { create(:account) }
    let(:agent) { create(:user, email: 'agent1@example.com', account: account, auto_offline: false) }
    let(:inbox) { create(:inbox, account: account) }
    let(:conversation) do
      create(
        :conversation,
        account: account,
        contact: create(:contact, account: account),
        inbox: inbox,
        assignee: nil
      )
    end

    before do
      # This shared example covers the legacy (v1) synchronous assignment path,
      # which is what it stubs (Redis::Alfred.rpoplpush) and asserts on
      # synchronously via conversation.reload. assignment_v2 defaults to
      # enabled (config/features.yml) and dispatches through an async
      # AutoAssignment::AssignmentJob instead — that path has no dedicated
      # coverage yet (see spawned follow-up task).
      #
      # account.disable_features!('assignment_v2') does NOT work here: for any
      # feature with `enabled: true` in config/features.yml, Featurable#feature_enabled?
      # can't distinguish "explicitly disabled" from "never set" and always falls
      # back to the YAML default (separately flagged as its own bug). Stubbing the
      # inbox method directly sidesteps that broken toggle for this test.
      # rubocop:disable RSpec/AnyInstance -- the Conversation callback resolves its
      # own `inbox` association internally; there's no handle to the exact instance
      # to stub before the after_save callback fires.
      allow_any_instance_of(Inbox).to receive(:auto_assignment_v2_enabled?).and_return(false)
      # rubocop:enable RSpec/AnyInstance
      create(:inbox_member, inbox: inbox, user: agent)
      allow(Redis::Alfred).to receive(:rpoplpush).and_return(agent.id)
    end

    it 'runs round robin on after_save callbacks' do
      expect(conversation.reload.assignee).to eq(agent)
    end

    it 'will not auto assign agent if enable_auto_assignment is false' do
      inbox.update(enable_auto_assignment: false)

      expect(conversation.reload.assignee).to be_nil
    end

    it 'will not auto assign agent if its a bot conversation' do
      conversation = create(
        :conversation,
        account: account,
        contact: create(:contact, account: account),
        inbox: inbox,
        status: 'pending',
        assignee: nil
      )

      expect(conversation.reload.assignee).to be_nil
    end

    it 'gets triggered on update only when status changes to open' do
      conversation.status = 'resolved'
      conversation.save!
      expect(conversation.reload.assignee).to eq(agent)
      inbox.inbox_members.where(user_id: agent.id).first.destroy!

      # round robin changes assignee in this case since agent doesn't have access to inbox
      agent2 = create(:user, email: 'agent2@example.com', account: account, auto_offline: false)
      create(:inbox_member, inbox: inbox, user: agent2)
      allow(Redis::Alfred).to receive(:rpoplpush).and_return(agent2.id)
      conversation.status = 'open'
      conversation.save!
      expect(conversation.reload.assignee).to eq(agent2)
    end
  end
end
