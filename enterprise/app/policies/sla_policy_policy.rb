class SlaPolicyPolicy < ApplicationPolicy
  def index?
    @account_user.administrator? || @account_user.agent?
  end

  def update?
    administrator_or_custom_role_permission?('sla_manage')
  end

  def show?
    @account_user.administrator? || @account_user.agent?
  end

  def create?
    administrator_or_custom_role_permission?('sla_manage')
  end

  def destroy?
    administrator_or_custom_role_permission?('sla_manage')
  end
end
