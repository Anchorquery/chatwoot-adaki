require 'rails_helper'

RSpec.describe AgentNotifications::ConversationNotificationsMailer, type: :mailer do
  let(:class_instance) { described_class.new }
  let(:account) { create(:account, locale: 'es') }
  let(:agent) { create(:user, email: 'agente@example.com', account: account, name: 'Ana') }
  let(:inbox) { create(:inbox, account: account, name: 'Puntua') }
  let(:conversation) { create(:conversation, account: account, inbox: inbox) }

  before do
    allow(described_class).to receive(:new).and_return(class_instance)
    allow(class_instance).to receive(:smtp_config_set_or_development?).and_return(true)
  end

  describe 'captain_unattended_handoff' do
    let(:mail) { described_class.with(account: account).captain_unattended_handoff(conversation, agent, nil).deliver_now }

    it 'renders the subject in the account locale' do
      expect(mail.subject).to eq("#{agent.available_name}, la conversación [ID - #{conversation.display_id}] de Puntua está esperando a un humano")
    end

    it 'is addressed to the agent and links to the conversation' do
      expect(mail.to).to eq([agent.email])
      expect(mail.body.encoded).to include("/app/accounts/#{account.id}/conversations/#{conversation.display_id}")
      expect(mail.body.encoded).to include('Abrir la conversaci')
    end
  end
end
