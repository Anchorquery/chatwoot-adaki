# frozen_string_literal: true

require 'rails_helper'

# Covers the assignment_v2 async path end-to-end: after_save enqueues
# AutoAssignment::AssignmentJob (Redis in-flight lock), perform_enqueued_jobs
# runs it synchronously, and AssignmentService/RoundRobinSelector/
# InboxRoundRobinService run for real (no collaborator mocking) so the
# resulting conversation.reload.assignee reflects the whole enqueue -> job ->
# service -> assignment cycle. This is the path config/features.yml enables
# by default; the legacy v1 path is covered separately in
# auto_assignment_handler_shared.rb.
shared_examples_for 'auto_assignment_handler_v2' do
  describe '#auto assignment (v2 async path)' do
    let(:account) { create(:account) }
    let(:inbox) { create(:inbox, account: account) }
    let(:agent) { create(:user, email: 'agent-v2@example.com', account: account, role: :agent) }

    before do
      account.enable_features('assignment_v2')
      account.save!
      create(:inbox_member, inbox: inbox, user: agent)
      allow(OnlineStatusTracker).to receive(:get_available_users).with(account.id).and_return({ agent.id.to_s => 'online' })
    end

    after do
      Redis::Alfred.delete(format(Redis::Alfred::AUTO_ASSIGNMENT_IN_FLIGHT_KEY, inbox_id: inbox.id))
    end

    it 'does not assign synchronously, then assigns once the enqueued job runs' do
      conversation = create(:conversation, account: account, inbox: inbox, assignee: nil)

      expect(conversation.reload.assignee).to be_nil

      perform_enqueued_jobs(only: AutoAssignment::AssignmentJob)

      expect(conversation.reload.assignee).to eq(agent)
    end

    it 'will not auto assign agent if enable_auto_assignment is false' do
      inbox.update!(enable_auto_assignment: false)
      conversation = create(:conversation, account: account, inbox: inbox, assignee: nil)

      perform_enqueued_jobs(only: AutoAssignment::AssignmentJob)

      expect(conversation.reload.assignee).to be_nil
    end

    it 'coalesces bursts of saves into a single enqueued job per inbox (Redis in-flight lock)' do
      create(:conversation, account: account, inbox: inbox, assignee: nil)
      create(:conversation, account: account, inbox: inbox, assignee: nil)

      matching_jobs = enqueued_jobs.select { |job| job[:job] == AutoAssignment::AssignmentJob }
      expect(matching_jobs.size).to eq(1)
    end

    it 'releases the in-flight marker once the job runs, allowing a later save to enqueue again' do
      create(:conversation, account: account, inbox: inbox, assignee: nil)
      perform_enqueued_jobs(only: AutoAssignment::AssignmentJob)

      key = format(Redis::Alfred::AUTO_ASSIGNMENT_IN_FLIGHT_KEY, inbox_id: inbox.id)
      expect(Redis::Alfred.get(key)).to be_nil

      second_conversation = create(:conversation, account: account, inbox: inbox, assignee: nil)
      expect(enqueued_jobs.count { |job| job[:job] == AutoAssignment::AssignmentJob }).to eq(1)

      perform_enqueued_jobs(only: AutoAssignment::AssignmentJob)

      expect(second_conversation.reload.assignee).to eq(agent)
    end

    it 'uses real round robin selection to distribute conversations across multiple agents' do
      agent2 = create(:user, email: 'agent-v2-2@example.com', account: account, role: :agent)
      create(:inbox_member, inbox: inbox, user: agent2)
      allow(OnlineStatusTracker).to receive(:get_available_users).with(account.id)
                                                                 .and_return({ agent.id.to_s => 'online', agent2.id.to_s => 'online' })

      first_conversation = create(:conversation, account: account, inbox: inbox, assignee: nil)
      perform_enqueued_jobs(only: AutoAssignment::AssignmentJob)

      second_conversation = create(:conversation, account: account, inbox: inbox, assignee: nil)
      perform_enqueued_jobs(only: AutoAssignment::AssignmentJob)

      assignees = [first_conversation.reload.assignee, second_conversation.reload.assignee]
      expect(assignees).to contain_exactly(agent, agent2)
    end
  end
end
