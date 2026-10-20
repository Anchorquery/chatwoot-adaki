class MacroPolicy < ApplicationPolicy
  def index?
    true
  end

  def create?
    true
  end

  def show?
    @record.global? || author?
  end

  def update?
    return administrator_or_custom_role_permission?('macro_manage') if @record.global?

    author?
  end

  def destroy?
    return administrator_or_custom_role_permission?('macro_manage') if @record.global?

    author?
  end

  def execute?
    @record.global? || author?
  end

  private

  def author?
    @record.created_by == @account_user.user
  end
end
