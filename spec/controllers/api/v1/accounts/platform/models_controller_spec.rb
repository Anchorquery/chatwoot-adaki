require 'rails_helper'

RSpec.describe 'Api::V1::Accounts::Platform::Models', type: :request do
  let(:account) { create(:account) }
  let(:admin) { create(:user, account: account, role: :administrator) }
  let(:credential) { create(:platform_credential, :openai, account: account) }
  let!(:model) do
    create(:platform_credential_model, credential: credential, slug: 'gpt-5.4-mini', kind: 'chat',
                                       reasoning_config: { 'supported_efforts' => %w[none low medium high xhigh], 'source' => 'seed' })
  end

  describe 'GET /api/v1/accounts/{account.id}/captain/platform/credentials/{credential.id}/models' do
    it 'exposes the reasoning capabilities of each model' do
      get "/api/v1/accounts/#{account.id}/captain/platform/credentials/#{credential.id}/models",
          headers: admin.create_new_auth_token, as: :json

      expect(response).to have_http_status(:success)
      expect(response.parsed_body.first['reasoning_config']).to include('supported_efforts' => %w[none low medium high xhigh])
    end
  end

  describe 'PUT /api/v1/accounts/{account.id}/captain/platform/credentials/{credential.id}/models/{id}' do
    it 'lets an operator override the accepted efforts and marks the row as manual' do
      put "/api/v1/accounts/#{account.id}/captain/platform/credentials/#{credential.id}/models/#{model.id}",
          params: { model: { reasoning_config: { supported_efforts: %w[low medium] } } },
          headers: admin.create_new_auth_token, as: :json

      expect(response).to have_http_status(:success)
      expect(model.reload.reasoning_config).to include('supported_efforts' => %w[low medium], 'source' => 'manual')
    end

    it 'rejects efforts outside the known vocabulary' do
      put "/api/v1/accounts/#{account.id}/captain/platform/credentials/#{credential.id}/models/#{model.id}",
          params: { model: { reasoning_config: { supported_efforts: %w[turbo] } } },
          headers: admin.create_new_auth_token, as: :json

      expect(response).to have_http_status(:unprocessable_entity)
    end
  end
end
