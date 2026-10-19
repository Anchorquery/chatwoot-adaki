require 'rails_helper'

# Each advanced settings page is opened by its own permission; billing,
# security and role management stay with administrators.
RSpec.describe 'Advanced settings API for custom roles', type: :request do
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account, role: :agent) }
  let(:headers) { user.create_new_auth_token }

  def give(*permissions)
    role = create(:custom_role, account: account, permissions: permissions)
    account.account_users.find_by(user_id: user.id).update!(custom_role: role)
  end

  {
    'audit_log_view' => ['audit logs', ->(account) { "/api/v1/accounts/#{account.id}/audit_logs" }],
    'integration_manage' => ['webhooks', ->(account) { "/api/v1/accounts/#{account.id}/webhooks" }],
    'automation_manage' => ['automation rules', ->(account) { "/api/v1/accounts/#{account.id}/automation_rules" }]
  }.each do |permission, (label, path)|
    describe label do
      it "can be read with #{permission}" do
        give(permission)

        get path.call(account), headers: headers, as: :json

        expect(response).to have_http_status(:success)
      end

      it "is closed without #{permission}" do
        give('conversation_manage', 'campaign_manage')

        get path.call(account), headers: headers, as: :json

        expect(response).to have_http_status(:unauthorized)
      end
    end
  end

  describe 'PATCH /api/v1/accounts/{account.id}' do
    it 'lets account_settings_manage edit the general settings' do
      give('account_settings_manage')

      patch "/api/v1/accounts/#{account.id}", params: { name: 'Renamed' }, headers: headers, as: :json

      expect(response).to have_http_status(:success)
      expect(account.reload.name).to eq('Renamed')
    end

    it 'keeps the general settings closed without it' do
      give('conversation_manage')

      patch "/api/v1/accounts/#{account.id}", params: { name: 'Renamed' }, headers: headers, as: :json

      expect(response).to have_http_status(:unauthorized)
    end
  end

  it 'never lets a role create custom roles, only administrators' do
    give(*CustomRole::PERMISSIONS)

    post "/api/v1/accounts/#{account.id}/custom_roles",
         params: { custom_role: { name: 'Escalation', description: 'x', permissions: ['conversation_manage'] } },
         headers: headers, as: :json

    expect(response).to have_http_status(:unauthorized)
  end

  it 'never lets a role read billing or delete the account' do
    give(*CustomRole::PERMISSIONS)

    post "/enterprise/api/v1/accounts/#{account.id}/toggle_deletion", params: { action_type: 'delete' }, headers: headers, as: :json

    expect(response).to have_http_status(:unauthorized)
  end
end
