require 'rails_helper'

RSpec.describe Captain::Conversation::FailureNotifier do
  let(:account) { create(:account) }
  let(:inbox) { create(:inbox, account: account) }
  let(:assistant) { create(:captain_assistant, account: account) }
  let(:conversation) { create(:conversation, inbox: inbox, account: account) }

  describe '#call' do
    %w[configuration limit_adaki].each do |failure_class|
      it "writes a private note when failure_class is #{failure_class.inspect}" do
        response = { 'failure_class' => failure_class, 'error' => 'Incorrect API key provided' }

        described_class.new(conversation: conversation, assistant: assistant, response: response).call

        note = conversation.messages.where(private: true).last
        expect(note).to be_present
        expect(note.content).to include(failure_class, 'Incorrect API key provided')
        expect(note.sender).to eq(assistant)
      end
    end

    %w[transient budget unknown].each do |failure_class|
      it "does not write anything when failure_class is #{failure_class.inspect} (not diagnosable)" do
        response = { 'failure_class' => failure_class, 'error' => 'some error' }

        described_class.new(conversation: conversation, assistant: assistant, response: response).call

        expect(conversation.messages).to be_empty
      end
    end

    it 'does not write anything when there is no failure_class at all (a legitimate escalation, not an infrastructure failure)' do
      described_class.new(conversation: conversation, assistant: assistant, response: { 'response' => 'conversation_handoff' }).call

      expect(conversation.messages).to be_empty
    end

    it 'prefers the human-readable error message over the coded action_reason' do
      response = {
        'failure_class' => 'configuration',
        'error' => 'Incorrect API key provided',
        'action_reason' => 'ruby_llm_unauthorized_error'
      }

      described_class.new(conversation: conversation, assistant: assistant, response: response).call

      expect(conversation.messages.last.content).to include('Incorrect API key provided')
      expect(conversation.messages.last.content).not_to include('ruby_llm_unauthorized_error')
    end

    it 'falls back to action_reason when no error message is present' do
      response = { 'failure_class' => 'configuration', 'action_reason' => 'ruby_llm_unauthorized_error' }

      described_class.new(conversation: conversation, assistant: assistant, response: response).call

      expect(conversation.messages.last.content).to include('ruby_llm_unauthorized_error')
    end

    context 'when mentioning whoever should act on the failure' do
      let(:response) { { 'failure_class' => 'configuration', 'error' => 'You exceeded your current quota' } }
      let(:agent) { create(:user, account: account, name: 'Ana Pérez') }
      let(:team) { create(:team, account: account, name: 'Soporte') }

      it '@mentions the assignee when the handoff assigned someone' do
        conversation.update!(assignee: agent)

        described_class.new(conversation: conversation, assistant: assistant, response: response).call

        note = conversation.messages.where(private: true).last
        expect(note.content).to start_with("[@Ana Pérez](mention://user/#{agent.id}/Ana%20P%C3%A9rez)")
        expect(note.content).to include('You exceeded your current quota')
      end

      it "@mentions the conversation's team when nobody is assigned yet" do
        conversation.update!(team: team)

        described_class.new(conversation: conversation, assistant: assistant, response: response).call

        expect(conversation.messages.where(private: true).last.content).to start_with("[@#{team.name}](mention://team/#{team.id}/#{team.name})")
      end

      it "@mentions the inbox's configured Captain handoff team when the conversation has none" do
        create(:captain_inbox, inbox: inbox, captain_assistant: assistant, settings: { 'handoff_team_id' => team.id })

        described_class.new(conversation: conversation.reload, assistant: assistant, response: response).call

        expect(conversation.messages.where(private: true).last.content).to start_with("[@#{team.name}](mention://team/#{team.id}/#{team.name})")
      end

      it 'prefers the assignee over the team' do
        create(:team_member, team: team, user: agent)
        conversation.update!(assignee: agent, team: team)

        described_class.new(conversation: conversation, assistant: assistant, response: response).call

        expect(conversation.messages.where(private: true).last.content).to start_with('[@Ana Pérez]')
      end

      it 'writes a plain note when there is nobody to mention' do
        described_class.new(conversation: conversation, assistant: assistant, response: response).call

        expect(conversation.messages.where(private: true).last.content).to start_with('[Captain] Handoff automático')
      end
    end

    it 'tolerates a nil response instead of raising' do
      expect do
        described_class.new(conversation: conversation, assistant: assistant, response: nil).call
      end.not_to raise_error

      expect(conversation.messages).to be_empty
    end

    it 'swallows its own failure to create the note rather than breaking the handoff' do
      allow(conversation.messages).to receive(:create!).and_raise(StandardError, 'db unavailable')
      response = { 'failure_class' => 'configuration', 'error' => 'x' }

      expect do
        described_class.new(conversation: conversation, assistant: assistant, response: response).call
      end.not_to raise_error
    end
  end
end
