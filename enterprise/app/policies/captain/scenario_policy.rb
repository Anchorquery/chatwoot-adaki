class Captain::ScenarioPolicy < ApplicationPolicy
  def index?
    true
  end

  def show?
    true
  end

  def create?
    administrator_or_custom_role_permission?('captain_manage')
  end

  def update?
    administrator_or_custom_role_permission?('captain_manage')
  end

  def destroy?
    administrator_or_custom_role_permission?('captain_manage')
  end

  def generate?
    administrator_or_custom_role_permission?('captain_manage')
  end
end
