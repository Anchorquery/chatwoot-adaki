class LabelPolicy < ApplicationPolicy
  def index?
    @account_user.administrator? || @account_user.agent? ||
      @account_user.permissions.include?('agent_settings_manage')
  end

  def update?
    administrator_or_custom_role_permission?('agent_settings_manage')
  end

  def show?
    administrator_or_custom_role_permission?('agent_settings_manage')
  end

  def create?
    administrator_or_custom_role_permission?('agent_settings_manage')
  end

  def destroy?
    administrator_or_custom_role_permission?('agent_settings_manage')
  end
end
