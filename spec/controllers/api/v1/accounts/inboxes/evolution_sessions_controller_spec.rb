require 'rails_helper'

RSpec.describe 'Inbox Evolution session API', type: :request do
  let(:account) { create(:account) }
  let(:admin) { create(:user, account: account, role: :administrator) }
  let(:agent) { create(:user, account: account, role: :agent) }

  describe 'POST /api/v1/accounts/{account.id}/inboxes/evolution_create' do
    let(:service_double) { instance_double(Evolution::InstanceService) }

    before { allow(Evolution::InstanceService).to receive(:new).and_return(service_double) }

    it 'creates the session and returns the new inbox' do
      inbox = create(:inbox, account: account, name: 'Soporte')
      allow(service_double).to receive(:create_inbox).with(name: 'Soporte').and_return(inbox)

      post "/api/v1/accounts/#{account.id}/inboxes/evolution_create",
           params: { name: 'Soporte' },
           headers: admin.create_new_auth_token,
           as: :json

      expect(response).to have_http_status(:created)
      expect(response.parsed_body['id']).to eq(inbox.id)
    end

    it 'maps a duplicated name to 422' do
      allow(service_double).to receive(:create_inbox).and_raise(Evolution::InstanceService::Error, 'name_taken')

      post "/api/v1/accounts/#{account.id}/inboxes/evolution_create",
           params: { name: 'Soporte' },
           headers: admin.create_new_auth_token,
           as: :json

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body).to eq('error' => 'name_taken')
    end

    it 'maps an Evolution failure to 502' do
      allow(service_double).to receive(:create_inbox).and_raise(Evolution::InstanceService::Error, 'unreachable')

      post "/api/v1/accounts/#{account.id}/inboxes/evolution_create",
           params: { name: 'Soporte' },
           headers: admin.create_new_auth_token,
           as: :json

      expect(response).to have_http_status(:bad_gateway)
    end

    it 'returns unauthorized for an agent' do
      post "/api/v1/accounts/#{account.id}/inboxes/evolution_create",
           params: { name: 'Soporte' },
           headers: agent.create_new_auth_token,
           as: :json

      expect(response).to have_http_status(:unauthorized)
    end
  end

  describe 'connection endpoints' do
    let(:inbox) { create(:inbox, account: account) }
    let(:service_double) { instance_double(Evolution::ConnectionService) }

    before { allow(Evolution::ConnectionService).to receive(:new).and_return(service_double) }

    it 'returns the connection state with the linked profile' do
      allow(service_double).to receive(:connection_state)
        .and_return({ status: 'ok', state: 'open', phone_number: '34600111222', profile_name: 'Soporte' })

      get "/api/v1/accounts/#{account.id}/inboxes/#{inbox.id}/evolution_connection_state",
          headers: admin.create_new_auth_token,
          as: :json

      expect(response).to have_http_status(:success)
      expect(response.parsed_body).to eq('state' => 'open', 'phone_number' => '34600111222', 'profile_name' => 'Soporte')
    end

    it 'returns the QR code when connecting' do
      allow(service_double).to receive(:connect)
        .and_return({ status: 'ok', state: 'connecting', qr_code: 'data:image/png;base64,AAA', pairing_code: nil })

      post "/api/v1/accounts/#{account.id}/inboxes/#{inbox.id}/evolution_connect",
           headers: admin.create_new_auth_token,
           as: :json

      expect(response).to have_http_status(:success)
      expect(response.parsed_body).to include('state' => 'connecting', 'qr_code' => 'data:image/png;base64,AAA')
    end

    it 'answers 502 when Evolution cannot be reached' do
      allow(service_double).to receive(:connection_state).and_return({ status: 'unreachable' })

      get "/api/v1/accounts/#{account.id}/inboxes/#{inbox.id}/evolution_connection_state",
          headers: admin.create_new_auth_token,
          as: :json

      expect(response).to have_http_status(:bad_gateway)
      expect(response.parsed_body).to eq('error' => 'unreachable')
    end

    it 'answers 422 when the inbox is not linked to Evolution' do
      allow(service_double).to receive(:connect).and_return({ status: 'not_configured' })

      post "/api/v1/accounts/#{account.id}/inboxes/#{inbox.id}/evolution_connect",
           headers: admin.create_new_auth_token,
           as: :json

      expect(response).to have_http_status(:unprocessable_entity)
    end

    it 'returns the instance settings' do
      allow(service_double).to receive(:instance_settings)
        .and_return({ status: 'ok', settings: { 'groups_ignore' => true } })

      get "/api/v1/accounts/#{account.id}/inboxes/#{inbox.id}/evolution_instance_settings",
          headers: admin.create_new_auth_token,
          as: :json

      expect(response).to have_http_status(:success)
      expect(response.parsed_body).to eq('settings' => { 'groups_ignore' => true })
    end

    it 'saves only the permitted instance settings' do
      allow(service_double).to receive(:update_instance_settings).and_return({ success: true, message: 'ok' })

      post "/api/v1/accounts/#{account.id}/inboxes/#{inbox.id}/evolution_update_instance_settings",
           params: { groups_ignore: true, reject_call: false, wavoip_token: 'x' },
           headers: admin.create_new_auth_token,
           as: :json

      expect(response).to have_http_status(:success)
      expect(service_double).to have_received(:update_instance_settings) do |changes|
        expect(changes.to_h).to eq('groups_ignore' => true, 'reject_call' => false)
      end
    end

    it 'answers 502 when the restart fails in Evolution' do
      allow(service_double).to receive(:restart).and_return({ success: false, message: 'evolution_error' })

      post "/api/v1/accounts/#{account.id}/inboxes/#{inbox.id}/evolution_restart",
           headers: admin.create_new_auth_token,
           as: :json

      expect(response).to have_http_status(:bad_gateway)
    end

    it 'logs the session out' do
      allow(service_double).to receive(:logout).and_return({ success: true, message: 'ok' })

      post "/api/v1/accounts/#{account.id}/inboxes/#{inbox.id}/evolution_logout",
           headers: admin.create_new_auth_token,
           as: :json

      expect(response).to have_http_status(:success)
    end

    it 'returns unauthorized for an agent' do
      create(:inbox_member, user: agent, inbox: inbox)

      post "/api/v1/accounts/#{account.id}/inboxes/#{inbox.id}/evolution_connect",
           headers: agent.create_new_auth_token,
           as: :json

      expect(response).to have_http_status(:unauthorized)
    end
  end

  describe 'DELETE /api/v1/accounts/{account.id}/inboxes/{inbox.id}' do
    let(:service_double) { instance_double(Evolution::ConnectionService, delete_instance: { success: true }) }

    before { allow(Evolution::ConnectionService).to receive(:new).and_return(service_double) }

    def api_inbox(additional_attributes)
      channel = create(:channel_api, account: account, additional_attributes: additional_attributes)
      create(:inbox, account: account, channel: channel)
    end

    it 'deletes the Evolution instance that Chatwoot created' do
      inbox = api_inbox({ 'evolution_api_key' => 'tok', 'evolution_managed_instance' => true })

      delete "/api/v1/accounts/#{account.id}/inboxes/#{inbox.id}",
             headers: admin.create_new_auth_token,
             as: :json

      expect(response).to have_http_status(:success)
      expect(service_double).to have_received(:delete_instance)
    end

    # Una instancia vinculada a mano (creada desde el Manager de Evolution)
    # puede seguir en uso fuera de Chatwoot: no se toca.
    it 'leaves manually linked instances alone' do
      inbox = api_inbox({ 'evolution_api_key' => 'tok' })

      delete "/api/v1/accounts/#{account.id}/inboxes/#{inbox.id}",
             headers: admin.create_new_auth_token,
             as: :json

      expect(response).to have_http_status(:success)
      expect(service_double).not_to have_received(:delete_instance)
    end

    it 'still deletes the inbox when Evolution fails' do
      inbox = api_inbox({ 'evolution_api_key' => 'tok', 'evolution_managed_instance' => true })
      allow(service_double).to receive(:delete_instance).and_raise(StandardError, 'boom')

      delete "/api/v1/accounts/#{account.id}/inboxes/#{inbox.id}",
             headers: admin.create_new_auth_token,
             as: :json

      expect(response).to have_http_status(:success)
    end
  end
end
