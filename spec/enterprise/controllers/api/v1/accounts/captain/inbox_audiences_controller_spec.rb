require 'rails_helper'

RSpec.describe 'Api::V1::Accounts::Captain::InboxAudiences', type: :request do
  let(:account) { create(:account) }
  let(:assistant) { create(:captain_assistant, account: account) }
  let(:inbox) { create(:inbox, account: account) }
  let!(:audience) do
    create(:captain_inbox_audience, captain_assistant: assistant, inbox: inbox, group_jids: ['1203630000000'])
  end
  let(:admin) { create(:user, account: account, role: :administrator) }
  let(:agent) { create(:user, account: account, role: :agent) }

  def json_response
    JSON.parse(response.body, symbolize_names: true)
  end

  describe 'GET /api/v1/accounts/:account_id/captain/assistants/:assistant_id/inbox_audiences' do
    context 'when user is authorized' do
      it 'returns a list of audiences for the assistant' do
        get "/api/v1/accounts/#{account.id}/captain/assistants/#{assistant.id}/inbox_audiences",
            headers: agent.create_new_auth_token

        expect(response).to have_http_status(:ok)
        expect(json_response[:payload].first[:id]).to eq(audience.id)
        expect(json_response[:payload].first[:group_jids]).to eq(['1203630000000'])
      end
    end

    context 'when user is unauthorized' do
      it 'returns unauthorized status' do
        get "/api/v1/accounts/#{account.id}/captain/assistants/#{assistant.id}/inbox_audiences"

        expect(response).to have_http_status(:unauthorized)
      end
    end
  end

  describe 'POST /api/v1/accounts/:account_id/captain/assistants/:assistant_id/inbox_audiences' do
    let(:valid_params) do
      {
        captain_inbox_audience: {
          inbox_id: inbox.id,
          group_jids: ['1203630000001'],
          label_titles: ['vip']
        }
      }
    end

    context 'when user is authorized' do
      it 'creates a new audience' do
        expect do
          post "/api/v1/accounts/#{account.id}/captain/assistants/#{assistant.id}/inbox_audiences",
               params: valid_params,
               headers: admin.create_new_auth_token
        end.to change(CaptainInboxAudience, :count).by(1)

        expect(response).to have_http_status(:success)
        expect(json_response[:group_jids]).to eq(['1203630000001'])
        expect(json_response[:label_titles]).to eq(['vip'])
      end

      context 'when inbox does not exist' do
        it 'returns not found status' do
          post "/api/v1/accounts/#{account.id}/captain/assistants/#{assistant.id}/inbox_audiences",
               params: { captain_inbox_audience: { inbox_id: 999_999, group_jids: ['123'] } },
               headers: admin.create_new_auth_token

          expect(response).to have_http_status(:not_found)
        end
      end

      context 'when neither group_jids nor label_titles are present' do
        it 'returns unprocessable entity status' do
          post "/api/v1/accounts/#{account.id}/captain/assistants/#{assistant.id}/inbox_audiences",
               params: { captain_inbox_audience: { inbox_id: inbox.id } },
               headers: admin.create_new_auth_token

          expect(response).to have_http_status(:unprocessable_entity)
        end
      end
    end

    context 'when user is agent' do
      it 'returns unauthorized status' do
        post "/api/v1/accounts/#{account.id}/captain/assistants/#{assistant.id}/inbox_audiences",
             params: valid_params,
             headers: agent.create_new_auth_token

        expect(response).to have_http_status(:unauthorized)
      end
    end
  end

  describe 'PATCH /api/v1/accounts/:account_id/captain/assistants/:assistant_id/inbox_audiences/:id' do
    context 'when user is authorized' do
      it 'updates the audience filters' do
        patch "/api/v1/accounts/#{account.id}/captain/assistants/#{assistant.id}/inbox_audiences/#{audience.id}",
              params: { captain_inbox_audience: { group_jids: ['999999999999'] } },
              headers: admin.create_new_auth_token

        expect(response).to have_http_status(:success)
        expect(audience.reload.group_jids).to eq(['999999999999'])
      end
    end
  end

  describe 'DELETE /api/v1/accounts/:account_id/captain/assistants/:assistant_id/inbox_audiences/:id' do
    context 'when user is authorized' do
      it 'deletes the audience' do
        expect do
          delete "/api/v1/accounts/#{account.id}/captain/assistants/#{assistant.id}/inbox_audiences/#{audience.id}",
                 headers: admin.create_new_auth_token
        end.to change(CaptainInboxAudience, :count).by(-1)

        expect(response).to have_http_status(:no_content)
      end

      context 'when audience does not exist' do
        it 'returns not found status' do
          delete "/api/v1/accounts/#{account.id}/captain/assistants/#{assistant.id}/inbox_audiences/999999",
                 headers: admin.create_new_auth_token

          expect(response).to have_http_status(:not_found)
        end
      end
    end
  end
end
