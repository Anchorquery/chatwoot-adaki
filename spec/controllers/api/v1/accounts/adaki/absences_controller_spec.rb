require 'rails_helper'

RSpec.describe 'Adaki Absences API', type: :request do
  let(:account) { create(:account) }
  let(:admin) { create(:user, account: account, role: :administrator) }
  let(:agent) { create(:user, account: account, role: :agent) }
  let(:absent_user) { create(:user, account: account) }
  let(:coverage_user) { create(:user, account: account) }

  let(:base_path) { "/api/v1/accounts/#{account.id}/adaki/absences" }
  let(:valid_payload) do
    {
      absence: {
        user_id: absent_user.id,
        coverage_user_id: coverage_user.id,
        start_at: 1.day.from_now.iso8601,
        end_at: 5.days.from_now.iso8601,
        reason: 'Vacation'
      }
    }
  end

  describe 'GET index' do
    it 'unauthorized without auth' do
      get base_path
      expect(response).to have_http_status(:unauthorized)
    end

    it 'agent can list' do
      create(:adaki_absence, account: account, user: absent_user)
      get base_path, headers: agent.create_new_auth_token, as: :json
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.size).to eq(1)
    end

    it 'tenant isolated' do
      other = create(:account)
      other_user = create(:user, account: other)
      create(:adaki_absence, account: other, user: other_user)

      get base_path, headers: admin.create_new_auth_token, as: :json
      expect(response.parsed_body).to be_empty
    end
  end

  describe 'POST create' do
    it 'agent cannot create' do
      post base_path, params: valid_payload, headers: agent.create_new_auth_token, as: :json
      expect(response).to have_http_status(:forbidden).or have_http_status(:unauthorized)
    end

    it 'admin creates + audit entry' do
      expect do
        post base_path, params: valid_payload, headers: admin.create_new_auth_token, as: :json
      end.to change(Adaki::Absence, :count).by(1)
                                           .and change(Adaki::AuditLogEntry, :count).by(1)
      expect(response).to have_http_status(:created)
      expect(Adaki::AuditLogEntry.last.action).to eq('absence.created')
    end
  end

  describe 'PATCH update' do
    let(:absence) { create(:adaki_absence, account: account, user: absent_user) }

    it 'admin updates' do
      patch "#{base_path}/#{absence.id}",
            params: { absence: { reason: 'Sick leave' } },
            headers: admin.create_new_auth_token, as: :json
      expect(response).to have_http_status(:ok)
      expect(absence.reload.reason).to eq('Sick leave')
    end

    it 'user_id is immutable' do
      other_user = create(:user, account: account)
      patch "#{base_path}/#{absence.id}",
            params: { absence: { user_id: other_user.id, reason: 'x' } },
            headers: admin.create_new_auth_token, as: :json
      expect(absence.reload.user_id).to eq(absent_user.id)
    end
  end

  describe 'DELETE destroy' do
    let(:absence) { create(:adaki_absence, account: account, user: absent_user) }

    it 'marks cancelled and logs audit' do
      expect do
        delete "#{base_path}/#{absence.id}", headers: admin.create_new_auth_token, as: :json
      end.to change(Adaki::AuditLogEntry, :count).by(1)
      expect(absence.reload.status).to eq('cancelled')
    end
  end
end
