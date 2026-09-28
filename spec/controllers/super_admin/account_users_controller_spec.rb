require 'rails_helper'

RSpec.describe 'Super Admin Account Users API', type: :request do
  let(:super_admin) { create(:super_admin) }

  describe 'GET /super_admin/account_users/new' do
    context 'when it is an unauthenticated super admin' do
      it 'returns unauthorized' do
        get '/super_admin/account_users/new'
        expect(response).to have_http_status(:redirect)
      end
    end

    context 'when it is an authenticated super admin' do
      it 'shows the account user create page' do
        sign_in(super_admin, scope: :super_admin)
        get '/super_admin/account_users/new'
        expect(response).to have_http_status(:success)
      end
    end
  end

  describe 'POST /super_admin/account_users' do
    let(:account) { create(:account) }
    let(:user) { create(:user) }
    let(:custom_role) { create(:custom_role, account: account) }

    before { sign_in(super_admin, scope: :super_admin) }

    def create_account_user(role)
      post '/super_admin/account_users',
           params: { account_user: { account_id: account.id, user_id: user.id, role: role } },
           headers: { 'HTTP_REFERER' => "/super_admin/accounts/#{account.id}" }
    end

    it 'adds the user with a built-in role' do
      create_account_user('administrator')

      expect(AccountUser.find_by(account: account, user: user)).to be_administrator
    end

    it 'adds the user as agent with the selected custom role' do
      create_account_user("custom_#{custom_role.id}")

      account_user = AccountUser.find_by(account: account, user: user)
      expect(account_user).to be_agent
      expect(account_user.custom_role).to eq(custom_role)
    end

    it 'updates the role of a user already in the account' do
      create(:account_user, account: account, user: user, role: :administrator)

      expect { create_account_user("custom_#{custom_role.id}") }.not_to change(AccountUser, :count)

      account_user = AccountUser.find_by(account: account, user: user)
      expect(account_user).to be_agent
      expect(account_user.custom_role).to eq(custom_role)
    end

    it 'clears the custom role when a built-in role is selected' do
      create(:account_user, account: account, user: user, custom_role: custom_role)

      create_account_user('administrator')

      account_user = AccountUser.find_by(account: account, user: user)
      expect(account_user).to be_administrator
      expect(account_user.custom_role).to be_nil
    end

    it 'rejects a custom role from another account' do
      other_role = create(:custom_role, account: create(:account))

      create_account_user("custom_#{other_role.id}")

      expect(AccountUser.find_by(account: account, user: user)).to be_nil
    end
  end

  describe 'GET /super_admin/accounts/:id' do
    it 'offers the account custom roles in the role select' do
      account = create(:account)
      create(:custom_role, account: account, name: 'Communication')
      create(:custom_role, account: create(:account), name: 'Other account role')
      sign_in(super_admin, scope: :super_admin)

      get "/super_admin/accounts/#{account.id}"

      expect(response.body).to include('administrator', 'Communication')
      expect(response.body).not_to include('Other account role')
    end
  end
end
