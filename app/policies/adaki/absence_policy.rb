class Adaki::AbsencePolicy < ApplicationPolicy
  def index?
    @account_user.administrator? || @account_user.agent?
  end

  def show?
    index?
  end

  def create?
    administrator_or_custom_role_permission?('absence_manage')
  end

  def update?
    administrator_or_custom_role_permission?('absence_manage')
  end

  def destroy?
    administrator_or_custom_role_permission?('absence_manage')
  end
end
