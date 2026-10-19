class HookPolicy < ApplicationPolicy
  def create?
    administrator_or_custom_role_permission?('integration_manage')
  end

  def update?
    administrator_or_custom_role_permission?('integration_manage')
  end

  def process_event?
    true
  end

  def destroy?
    administrator_or_custom_role_permission?('integration_manage')
  end
end
