require 'rails_helper'

RSpec.describe 'Adaki Audit Log API', type: :request do
  let(:account) { create(:account) }
  let(:admin) { create(:user, account: account, role: :administrator) }
  let(:agent) { create(:user, account: account, role: :agent) }

  let(:base_path) { "/api/v1/accounts/#{account.id}/adaki/audit_log_entries" }

  before do
    Adaki::AuditLogger.log(account: account, action: 'absence.created', user: admin)
    Adaki::AuditLogger.log(account: account, action: 'absence.updated', user: admin)
    Adaki::AuditLogger.log(account: account, action: 'campaign.approval.requested', user: admin)
  end

  describe 'GET index' do
    it 'unauthorized for agent' do
      get base_path, headers: agent.create_new_auth_token, as: :json
      expect(response).to have_http_status(:forbidden).or have_http_status(:unauthorized)
    end

    it 'lists entries for admin' do
      get base_path, headers: admin.create_new_auth_token, as: :json
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.size).to eq(3)
    end

    it 'filters by action' do
      get base_path, params: { action_filter: 'absence.created' },
                     headers: admin.create_new_auth_token, as: :json
      expect(response.parsed_body.size).to eq(1)
      expect(response.parsed_body.first['action']).to eq('absence.created')
    end

    it 'serializes user_email' do
      get base_path, headers: admin.create_new_auth_token, as: :json
      entry = response.parsed_body.find { |e| e['user_id'] == admin.id }
      expect(entry['user_email']).to eq(admin.email)
    end

    it 'tenant isolated' do
      other = create(:account)
      Adaki::AuditLogger.log(account: other, action: 'other.action')

      get base_path, headers: admin.create_new_auth_token, as: :json
      expect(response.parsed_body.size).to eq(3)
    end
  end

  describe 'GET verify' do
    it 'returns valid when chain intact' do
      get "#{base_path}/verify", headers: admin.create_new_auth_token, as: :json
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body['valid']).to be true
    end

    it 'returns invalid when tampered' do
      entry = Adaki::AuditLogEntry.for_account(account).first
      # update_columns is blocked by the model's own readonly? guard (append-only
      # by design). Simulate an attacker tampering with the row directly in the
      # DB, bypassing the ActiveRecord instance entirely.
      Adaki::AuditLogEntry.where(id: entry.id).update_all(payload: { tampered: true }) # rubocop:disable Rails/SkipsModelValidations

      get "#{base_path}/verify", headers: admin.create_new_auth_token, as: :json
      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body['valid']).to be false
      expect(response.parsed_body['error']).to be_present
    end
  end
end
