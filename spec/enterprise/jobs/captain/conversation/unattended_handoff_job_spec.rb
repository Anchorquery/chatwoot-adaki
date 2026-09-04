require 'rails_helper'

RSpec.describe Captain::Conversation::UnattendedHandoffJob do
  let(:account) { create(:account) }
  let(:inbox) { create(:inbox, account: account) }
  let(:assistant) { create(:captain_assistant, account: account) }
  let(:team) { create(:team, account: account, name: 'Soporte') }
  let(:member_one) { create(:user, account: account, name: 'Ana') }
  let(:member_two) { create(:user, account: account, name: 'Luis') }
  let(:outsider) { create(:user, account: account, name: 'Pepe') }
  let(:handoff_at) { 2.minutes.ago.change(usec: 0) }
  let(:conversation) do
    create(:conversation, account: account, inbox: inbox, status: :open,
                          additional_attributes: { 'captain_handoff_at' => handoff_at.iso8601 })
  end
  let(:mailer) { instance_double(AgentNotifications::ConversationNotificationsMailer) }
  let(:mail) { instance_double(ActionMailer::MessageDelivery, deliver_later: true) }

  before do
    create(:captain_inbox, inbox: inbox, captain_assistant: assistant, settings: { 'handoff_team_id' => team.id })
    [member_one, member_two, outsider].each { |user| create(:inbox_member, inbox: inbox, user: user) }
    [member_one, member_two].each { |user| create(:team_member, team: team, user: user) }
    allow(AgentNotifications::ConversationNotificationsMailer).to receive(:with).and_return(mailer)
    allow(mailer).to receive(:captain_unattended_handoff).and_return(mail)
    # A Captain-enabled inbox creates conversations as pending; a handoff leaves them open.
    conversation.update!(status: :open)
  end

  def perform
    described_class.perform_now(conversation, handoff_at.iso8601)
  end

  it 'leaves a private note that @mentions the handoff team' do
    perform

    note = conversation.messages.where(private: true).last
    expect(note).to be_present
    expect(note.sender).to eq(assistant)
    expect(note.content).to include("[@#{team.name}](mention://team/#{team.id}/#{team.name})")
  end

  it 'emails every team member and nobody else' do
    perform

    expect(mailer).to have_received(:captain_unattended_handoff).with(conversation, member_one, nil)
    expect(mailer).to have_received(:captain_unattended_handoff).with(conversation, member_two, nil)
    expect(mailer).not_to have_received(:captain_unattended_handoff).with(conversation, outsider, nil)
  end

  it 'does not announce the same handoff twice' do
    perform
    perform

    expect(conversation.messages.where(private: true).count).to eq(1)
    expect(mailer).to have_received(:captain_unattended_handoff).twice
  end

  it 'stays quiet when someone was assigned meanwhile' do
    conversation.update!(assignee: member_one)

    perform

    expect(conversation.messages.where(private: true)).to be_empty
    expect(mailer).not_to have_received(:captain_unattended_handoff)
  end

  it 'stays quiet when a human already replied' do
    create(:message, conversation: conversation, account: account, inbox: inbox, message_type: :outgoing,
                     sender: member_one, content: 'Hola, ya te atiendo')

    perform

    expect(mailer).not_to have_received(:captain_unattended_handoff)
  end

  it 'stays quiet when the conversation is no longer open' do
    conversation.update!(status: :resolved)

    perform

    expect(mailer).not_to have_received(:captain_unattended_handoff)
  end

  it 'ignores a stale check once a newer handoff replaced this one' do
    conversation.update!(additional_attributes: { 'captain_handoff_at' => Time.current.iso8601 })

    perform

    expect(mailer).not_to have_received(:captain_unattended_handoff)
  end

  context 'without a handoff team' do
    before { inbox.captain_inbox.update!(settings: {}) }

    it 'falls back to every inbox collaborator, mentioning each one' do
      perform

      note = conversation.messages.where(private: true).last
      expect(note.content).to include("mention://user/#{member_one.id}/", "mention://user/#{outsider.id}/")
      expect(mailer).to have_received(:captain_unattended_handoff).exactly(3).times
    end
  end
end
