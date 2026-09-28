require 'rails_helper'

RSpec.describe 'Super Admin Account Users API with custom roles', type: :request do
  let(:super_admin) { create(:super_admin) }
  let(:account) { create(:account) }
  let(:user) { create(:user) }
  let(:custom_role) { create(:custom_role, account: account) }

  before { sign_in(super_admin, scope: :super_admin) }

  describe 'POST /super_admin/account_users' do
    def create_account_user(role)
      post '/super_admin/account_users',
           params: { account_user: { account_id: account.id, user_id: user.id, role: role } },
           headers: { 'HTTP_REFERER' => "/super_admin/accounts/#{account.id}" }
    end

    it 'adds the user as agent with the selected custom role' do
      create_account_user("custom_#{custom_role.id}")

      account_user = AccountUser.find_by(account: account, user: user)
      expect(account_user).to be_agent
      expect(account_user.custom_role).to eq(custom_role)
    end

    it 'demotes an administrator already in the account to agent with the custom role' do
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
      create(:custom_role, account: account, name: 'Communication')
      create(:custom_role, account: create(:account), name: 'Other account role')

      get "/super_admin/accounts/#{account.id}"

      expect(response.body).to include('administrator', 'Communication')
      expect(response.body).not_to include('Other account role')
    end
  end
end
