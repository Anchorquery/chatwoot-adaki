require 'rails_helper'

RSpec.describe 'Super Admin Custom Roles API', type: :request do
  let(:super_admin) { create(:super_admin) }
  let(:account) { create(:account) }

  describe 'GET /super_admin/custom_roles' do
    it 'redirects an unauthenticated user' do
      get '/super_admin/custom_roles'

      expect(response).to have_http_status(:redirect)
    end

    it 'lists the custom roles of every account' do
      create(:custom_role, account: account, name: 'Communication')
      sign_in(super_admin, scope: :super_admin)

      get '/super_admin/custom_roles'

      expect(response).to have_http_status(:success)
      expect(response.body).to include('Communication')
    end
  end

  describe 'GET /super_admin/custom_roles/new' do
    it 'shows every permission and sidebar profile' do
      sign_in(super_admin, scope: :super_admin)

      get '/super_admin/custom_roles/new'

      expect(response).to have_http_status(:success)
      expect(response.body).to include(*CustomRole::PERMISSIONS, *CustomRole::SIDEBAR_PROFILES)
      expect(response.body).to include('Manage all conversations', 'Community communications (manage campaigns)')
    end

    it 'preselects the default sidebar instead of the first profile' do
      sign_in(super_admin, scope: :super_admin)

      get '/super_admin/custom_roles/new'

      expect(response.body).to match(%r{<option selected="selected" value="">Default sidebar</option>})
    end
  end

  describe 'POST /super_admin/custom_roles' do
    before { sign_in(super_admin, scope: :super_admin) }

    it 'creates a custom role with permissions and sidebar profile' do
      post '/super_admin/custom_roles', params: {
        custom_role: {
          account_id: account.id, name: 'AI team', description: 'Captain only',
          sidebar_profile: 'ai_agent', permissions: ['', 'contact_manage', 'report_manage']
        }
      }

      custom_role = account.custom_roles.last
      expect(custom_role.name).to eq('AI team')
      expect(custom_role.sidebar_profile).to eq('ai_agent')
      expect(custom_role.permissions).to eq(%w[contact_manage report_manage])
    end

    it 'creates a custom role without sidebar profile or permissions' do
      post '/super_admin/custom_roles', params: {
        custom_role: { account_id: account.id, name: 'Plain', sidebar_profile: '', permissions: [''] }
      }

      custom_role = account.custom_roles.last
      expect(custom_role.sidebar_profile).to be_nil
      expect(custom_role.permissions).to eq([])
    end
  end

  describe 'PATCH /super_admin/custom_roles/:id' do
    it 'updates the permissions' do
      custom_role = create(:custom_role, account: account, permissions: %w[contact_manage])
      sign_in(super_admin, scope: :super_admin)

      patch "/super_admin/custom_roles/#{custom_role.id}", params: {
        custom_role: { permissions: ['', 'conversation_manage'], sidebar_profile: 'communication' }
      }

      expect(custom_role.reload.permissions).to eq(%w[conversation_manage])
      expect(custom_role.sidebar_profile).to eq('communication')
    end
  end

  describe 'DELETE /super_admin/custom_roles/:id' do
    it 'deletes the role and detaches it from its users' do
      custom_role = create(:custom_role, account: account)
      account_user = create(:account_user, account: account, custom_role: custom_role)
      sign_in(super_admin, scope: :super_admin)

      delete "/super_admin/custom_roles/#{custom_role.id}"

      expect(CustomRole.exists?(custom_role.id)).to be(false)
      expect(account_user.reload.custom_role_id).to be_nil
    end
  end
end
