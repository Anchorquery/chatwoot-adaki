require 'rails_helper'

# channel_operate opens the WhatsApp session (state, QR, restart) of the
# inboxes the user is assigned to, and nothing else about channels.
RSpec.describe 'Inbox Evolution session API for channel operators', type: :request do
  let(:account) { create(:account) }
  let(:operator) { create(:user, account: account, role: :agent) }
  let(:inbox) { create(:inbox, account: account) }
  let(:service_double) { instance_double(Evolution::ConnectionService) }
  let(:base_url) { "/api/v1/accounts/#{account.id}/inboxes/#{inbox.id}" }
  let(:headers) { operator.create_new_auth_token }

  before do
    role = create(:custom_role, account: account, permissions: %w[conversation_manage channel_operate])
    account.account_users.find_by(user_id: operator.id).update!(custom_role: role)
    allow(Evolution::ConnectionService).to receive(:new).and_return(service_double)
  end

  context 'when the inbox is assigned to the user' do
    before { create(:inbox_member, user: operator, inbox: inbox) }

    it 'reads the connection state' do
      allow(service_double).to receive(:connection_state).and_return({ status: 'ok', state: 'open' })

      get "#{base_url}/evolution_connection_state", headers: headers, as: :json

      expect(response).to have_http_status(:success)
    end

    it 'requests the QR code' do
      allow(service_double).to receive(:connect).and_return({ status: 'ok', state: 'connecting', qr_code: 'data:image/png;base64,AAA' })

      post "#{base_url}/evolution_connect", headers: headers, as: :json

      expect(response).to have_http_status(:success)
    end

    it 'restarts the session' do
      allow(service_double).to receive(:restart).and_return({ success: true, message: 'ok' })

      post "#{base_url}/evolution_restart", headers: headers, as: :json

      expect(response).to have_http_status(:success)
    end

    it 'cannot log the number out' do
      post "#{base_url}/evolution_logout", headers: headers, as: :json

      expect(response).to have_http_status(:unauthorized)
    end

    it 'cannot read or change the instance settings' do
      get "#{base_url}/evolution_instance_settings", headers: headers, as: :json
      expect(response).to have_http_status(:unauthorized)

      post "#{base_url}/evolution_update_instance_settings", params: { groups_ignore: true }, headers: headers, as: :json
      expect(response).to have_http_status(:unauthorized)
    end

    it 'cannot create new Evolution sessions' do
      post "/api/v1/accounts/#{account.id}/inboxes/evolution_create", params: { name: 'Other' }, headers: headers, as: :json

      expect(response).to have_http_status(:unauthorized)
    end
  end

  context 'when the inbox is not assigned to the user' do
    it 'cannot operate the session' do
      get "#{base_url}/evolution_connection_state", headers: headers, as: :json
      expect(response).to have_http_status(:unauthorized)

      post "#{base_url}/evolution_connect", headers: headers, as: :json
      expect(response).to have_http_status(:unauthorized)

      post "#{base_url}/evolution_restart", headers: headers, as: :json
      expect(response).to have_http_status(:unauthorized)
    end
  end

  context 'when the role lacks channel_operate' do
    it 'does not let an assigned user operate the session' do
      role = create(:custom_role, account: account, permissions: %w[conversation_manage campaign_manage])
      account.account_users.find_by(user_id: operator.id).update!(custom_role: role)
      create(:inbox_member, user: operator, inbox: inbox)

      post "#{base_url}/evolution_connect", headers: headers, as: :json

      expect(response).to have_http_status(:unauthorized)
    end
  end
end
