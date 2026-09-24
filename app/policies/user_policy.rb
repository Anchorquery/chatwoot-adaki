class UserPolicy < ApplicationPolicy
  def index?
    true
  end

  def create?
    administrator_or_custom_role_permission?('agent_settings_manage')
  end

  def update?
    @account_user.administrator? || (agent_settings_manager? && account_agent?)
  end

  def destroy?
    @account_user.administrator? || (agent_settings_manager? && account_agent?)
  end

  def bulk_create?
    @account_user.administrator?
  end

  private

  def agent_settings_manager?
    @account_user.permissions.include?('agent_settings_manage')
  end

  def account_agent?
    record.account_users.exists?(
      account_id: account.id,
      role: AccountUser.roles[:agent]
    )
  end
end
