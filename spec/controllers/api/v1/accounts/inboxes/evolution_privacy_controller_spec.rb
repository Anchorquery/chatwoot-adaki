require 'rails_helper'

RSpec.describe 'Inbox Evolution privacy API', type: :request do
  let(:account) { create(:account) }
  let(:admin) { create(:user, account: account, role: :administrator) }
  let(:agent) { create(:user, account: account, role: :agent) }
  let(:inbox) { create(:inbox, account: account, channel: create(:channel_api, account: account)) }
  let(:base) { "/api/v1/accounts/#{account.id}/inboxes/#{inbox.id}" }

  describe 'GET evolution_privacy_search' do
    let(:directory) { instance_double(Evolution::PrivacyDirectoryService, search: { items: [], has_more: false }) }

    before { allow(Evolution::PrivacyDirectoryService).to receive(:new).and_return(directory) }

    it 'searches every chat of the number for an administrator' do
      get "#{base}/evolution_privacy_search", params: { q: 'juan', type: 'contact', page: 2 }, headers: admin.create_new_auth_token

      expect(response).to have_http_status(:success)
      expect(Evolution::PrivacyDirectoryService).to have_received(:new).with(inbox: inbox, include_evolution: true)
      expect(directory).to have_received(:search).with(query: 'juan', type: 'contact', page: '2')
    end

    # Un agente asignado puede usar el filtro, pero sin ver los chats que el
    # filtro le oculta: solo busca entre los contactos de la bandeja.
    it 'limits an assigned agent to the contacts of the inbox' do
      create(:inbox_member, user: agent, inbox: inbox)

      get "#{base}/evolution_privacy_search", params: { q: 'juan' }, headers: agent.create_new_auth_token

      expect(response).to have_http_status(:success)
      expect(Evolution::PrivacyDirectoryService).to have_received(:new).with(inbox: inbox, include_evolution: false)
    end

    it 'rejects an agent who is not assigned to the inbox' do
      get "#{base}/evolution_privacy_search", headers: agent.create_new_auth_token

      expect(response).to have_http_status(:unauthorized)
    end
  end

  describe 'contact shortcut' do
    let(:contact) { create(:contact, account: account, identifier: '34600111222@s.whatsapp.net') }
    let(:service) { instance_double(Evolution::ContactPrivacyService, contact_jids: ['34600111222@s.whatsapp.net']) }

    before do
      create(:contact_inbox, contact: contact, inbox: inbox, source_id: 'abc')
      allow(Evolution::ContactPrivacyService).to receive(:new).and_return(service)
    end

    it 'reports whether the contact is filtered' do
      allow(service).to receive(:status).and_return({ status: 'ok', filtered: false, mode: 'block' })

      get "#{base}/evolution_privacy_contact", params: { contact_id: contact.id }, headers: admin.create_new_auth_token

      expect(response.parsed_body).to eq('filtered' => false, 'mode' => 'block', 'jids' => ['34600111222@s.whatsapp.net'])
    end

    it 'lets an assigned agent filter the contact' do
      create(:inbox_member, user: agent, inbox: inbox)
      allow(service).to receive(:update).and_return({ success: true, message: 'ok' })

      post "#{base}/evolution_update_privacy_contact", params: { contact_id: contact.id, filtered: true },
                                                       headers: agent.create_new_auth_token, as: :json

      expect(response).to have_http_status(:success)
      expect(service).to have_received(:update).with(filtered: true)
    end

    it 'explains why the last allowed chat cannot be removed' do
      allow(service).to receive(:update).and_return({ success: false, message: 'last_allowed' })

      post "#{base}/evolution_update_privacy_contact", params: { contact_id: contact.id, filtered: true },
                                                       headers: admin.create_new_auth_token, as: :json

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body['message']).to eq('last_allowed')
    end

    it 'does not touch contacts from another inbox' do
      other = create(:contact, account: account)

      get "#{base}/evolution_privacy_contact", params: { contact_id: other.id }, headers: admin.create_new_auth_token

      expect(response).to have_http_status(:not_found)
    end
  end

  describe 'POST evolution_update_privacy_filter' do
    let(:audience) { instance_double(Evolution::AudienceOptionsService, update_privacy_filter: { success: true, message: 'ok' }) }

    before { allow(Evolution::AudienceOptionsService).to receive(:new).and_return(audience) }

    it 'remembers the names of the saved chats' do
      post "#{base}/evolution_update_privacy_filter",
           params: { mode: 'block', jids: ['34600111222@s.whatsapp.net'], labels: { '34600111222@s.whatsapp.net' => 'Juan' } },
           headers: admin.create_new_auth_token, as: :json

      expect(response).to have_http_status(:success)
      expect(inbox.channel.reload.additional_attributes['evolution_privacy_labels']).to eq('34600111222@s.whatsapp.net' => 'Juan')
    end
  end
end
