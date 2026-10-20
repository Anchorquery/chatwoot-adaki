require 'rails_helper'

# campaign_manage opens every campaign action, including cloning and results,
# for a custom role; a role without it (or a plain agent) gets nothing.
RSpec.describe 'Campaigns API for custom roles', type: :request do
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account, role: :agent) }
  let(:headers) { user.create_new_auth_token }
  let!(:campaign) { create(:campaign, account: account, trigger_rules: { url: 'https://test.com' }) }

  def give(*permissions)
    role = create(:custom_role, account: account, permissions: permissions)
    account.account_users.find_by(user_id: user.id).update!(custom_role: role)
  end

  context 'with campaign_manage' do
    before { give('conversation_manage', 'campaign_manage') }

    it 'lists the campaigns' do
      get "/api/v1/accounts/#{account.id}/campaigns", headers: headers, as: :json

      expect(response).to have_http_status(:success)
    end

    it 'clones a campaign' do
      expect do
        post "/api/v1/accounts/#{account.id}/campaigns/#{campaign.display_id}/clone", headers: headers, as: :json
      end.to change(Campaign, :count).by(1)

      expect(response).to have_http_status(:success)
    end

    it 'reads the delivery results' do
      get "/api/v1/accounts/#{account.id}/campaigns/#{campaign.display_id}/results", headers: headers, as: :json

      expect(response).to have_http_status(:success)
    end
  end

  context 'without campaign_manage' do
    before { give('conversation_manage', 'contact_manage') }

    it 'cannot list, clone or read results' do
      get "/api/v1/accounts/#{account.id}/campaigns", headers: headers, as: :json
      expect(response).to have_http_status(:unauthorized)

      expect do
        post "/api/v1/accounts/#{account.id}/campaigns/#{campaign.display_id}/clone", headers: headers, as: :json
      end.not_to change(Campaign, :count)
      expect(response).to have_http_status(:unauthorized)

      get "/api/v1/accounts/#{account.id}/campaigns/#{campaign.display_id}/results", headers: headers, as: :json
      expect(response).to have_http_status(:unauthorized)
    end
  end

  it 'does not let a plain agent clone a campaign' do
    post "/api/v1/accounts/#{account.id}/campaigns/#{campaign.display_id}/clone", headers: headers, as: :json

    expect(response).to have_http_status(:unauthorized)
  end
end
