require 'rails_helper'

RSpec.describe 'Adaki Captain Settings API', type: :request do
  let(:account) { create(:account) }
  let(:admin) { create(:user, account: account, role: :administrator) }
  let(:agent) { create(:user, account: account, role: :agent) }

  describe 'GET /api/v1/accounts/:id/adaki/captain_settings' do
    it 'unauthorized for non-admin' do
      get "/api/v1/accounts/#{account.id}/adaki/captain_settings",
          headers: agent.create_new_auth_token, as: :json
      expect(response).to have_http_status(:forbidden).or have_http_status(:unauthorized)
    end

    it 'returns current limit and usage for admin' do
      account.update!(adaki_captain_monthly_limit: 500)
      Adaki::CaptainUsage.current_for(account).update!(request_count: 12, input_tokens: 100, output_tokens: 60)

      get "/api/v1/accounts/#{account.id}/adaki/captain_settings",
          headers: admin.create_new_auth_token, as: :json
      expect(response).to have_http_status(:ok)
      body = response.parsed_body
      expect(body['adaki_captain_monthly_limit']).to eq(500)
      expect(body['request_count']).to eq(12)
      expect(body['input_tokens']).to eq(100)
      expect(body['output_tokens']).to eq(60)
    end
  end

  describe 'PATCH /api/v1/accounts/:id/adaki/captain_settings' do
    it 'updates limit and writes audit' do
      expect do
        patch "/api/v1/accounts/#{account.id}/adaki/captain_settings",
              params: { adaki_captain_monthly_limit: 1000 },
              headers: admin.create_new_auth_token, as: :json
      end.to change(Adaki::AuditLogEntry, :count).by(1)
      expect(response).to have_http_status(:ok)
      expect(account.reload.adaki_captain_monthly_limit).to eq(1000)
      expect(Adaki::AuditLogEntry.last.action).to eq('captain.limit.updated')
    end

    it 'clears limit when nil' do
      account.update!(adaki_captain_monthly_limit: 100)
      patch "/api/v1/accounts/#{account.id}/adaki/captain_settings",
            params: { adaki_captain_monthly_limit: '' },
            headers: admin.create_new_auth_token, as: :json
      expect(response).to have_http_status(:ok)
      expect(account.reload.adaki_captain_monthly_limit).to be_nil
    end
  end
end
