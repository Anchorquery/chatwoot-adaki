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

    before { sign_in(super_admin, scope: :super_admin) }

    it 'adds the user with a built-in role' do
      post '/super_admin/account_users',
           params: { account_user: { account_id: account.id, user_id: user.id, role: 'administrator' } },
           headers: { 'HTTP_REFERER' => "/super_admin/accounts/#{account.id}" }

      expect(AccountUser.find_by(account: account, user: user)).to be_administrator
    end

    it 'updates the role of a user already in the account' do
      create(:account_user, account: account, user: user, role: :administrator)

      expect do
        post '/super_admin/account_users',
             params: { account_user: { account_id: account.id, user_id: user.id, role: 'agent' } },
             headers: { 'HTTP_REFERER' => "/super_admin/accounts/#{account.id}" }
      end.not_to change(AccountUser, :count)

      expect(AccountUser.find_by(account: account, user: user)).to be_agent
    end
  end
end
