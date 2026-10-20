class AuditLogPolicy < ApplicationPolicy
  def index?
    administrator_or_custom_role_permission?('audit_log_view')
  end

  def show?
    index?
  end
end
