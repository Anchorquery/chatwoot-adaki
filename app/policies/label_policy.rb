class LabelPolicy < ApplicationPolicy
  def index?
    @account_user.administrator? || @account_user.agent? ||
      @account_user.permissions.include?('label_manage')
  end

  def update?
    administrator_or_custom_role_permission?('label_manage')
  end

  def show?
    administrator_or_custom_role_permission?('label_manage')
  end

  def create?
    administrator_or_custom_role_permission?('label_manage')
  end

  def destroy?
    administrator_or_custom_role_permission?('label_manage')
  end
end
