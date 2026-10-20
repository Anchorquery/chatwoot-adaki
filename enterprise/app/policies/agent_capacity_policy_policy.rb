class AgentCapacityPolicyPolicy < ApplicationPolicy
  def index?
    administrator_or_custom_role_permission?('assignment_manage')
  end

  def create?
    administrator_or_custom_role_permission?('assignment_manage')
  end

  def show?
    administrator_or_custom_role_permission?('assignment_manage')
  end

  def update?
    administrator_or_custom_role_permission?('assignment_manage')
  end

  def destroy?
    administrator_or_custom_role_permission?('assignment_manage')
  end
end
