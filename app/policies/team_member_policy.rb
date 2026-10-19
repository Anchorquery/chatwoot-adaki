class TeamMemberPolicy < ApplicationPolicy
  def index?
    true
  end

  def create?
    administrator_or_custom_role_permission?('team_manage')
  end

  def destroy?
    administrator_or_custom_role_permission?('team_manage')
  end

  def update?
    administrator_or_custom_role_permission?('team_manage')
  end
end
