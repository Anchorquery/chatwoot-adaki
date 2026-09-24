class CustomRolePolicy < ApplicationPolicy
  def index?
    administrator_or_custom_role_permission?('agent_settings_manage')
  end

  def update?
    @account_user.administrator?
  end

  def show?
    @account_user.administrator?
  end

  def create?
    @account_user.administrator?
  end

  def destroy?
    @account_user.administrator?
  end
end
