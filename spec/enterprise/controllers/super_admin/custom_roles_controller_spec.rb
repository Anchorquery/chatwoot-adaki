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
    it 'shows every permission grouped by section' do
      sign_in(super_admin, scope: :super_admin)

      get '/super_admin/custom_roles/new'

      expect(response).to have_http_status(:success)
      expect(response.body).to include(*CustomRole::PERMISSIONS)
      expect(response.body).to include('Conversations', 'Campaigns', 'Channels (inboxes)', 'Team')
      expect(response.body).to include('Create, edit, clone and launch campaigns')
    end

    it 'offers the ready-made templates' do
      sign_in(super_admin, scope: :super_admin)

      get '/super_admin/custom_roles/new'

      expect(response.body).to include('Community communications', 'AI support agent')
      expect(response.body).to include(CustomRole::PRESETS['communication'].to_json.gsub('"', '&quot;'))
    end
  end

  describe 'POST /super_admin/custom_roles' do
    before { sign_in(super_admin, scope: :super_admin) }

    it 'creates a custom role with the ticked permissions' do
      post '/super_admin/custom_roles', params: {
        custom_role: {
          account_id: account.id, name: 'Communication', description: 'Campaigns',
          permissions: ['', 'campaign_manage', 'channel_operate', 'contact_manage']
        }
      }

      custom_role = account.custom_roles.last
      expect(custom_role.name).to eq('Communication')
      expect(custom_role.permissions).to eq(%w[campaign_manage channel_operate contact_manage])
    end

    it 'creates a custom role without permissions' do
      post '/super_admin/custom_roles', params: {
        custom_role: { account_id: account.id, name: 'Plain', permissions: [''] }
      }

      expect(account.custom_roles.last.permissions).to eq([])
    end
  end

  describe 'PATCH /super_admin/custom_roles/:id' do
    it 'updates the permissions' do
      custom_role = create(:custom_role, account: account, permissions: %w[contact_manage])
      sign_in(super_admin, scope: :super_admin)

      patch "/super_admin/custom_roles/#{custom_role.id}", params: {
        custom_role: { permissions: ['', 'conversation_manage', 'inbox_manage'] }
      }

      expect(custom_role.reload.permissions).to eq(%w[conversation_manage inbox_manage])
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
