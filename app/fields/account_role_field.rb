require 'administrate/field/base'

# Role picker for account users in super admin: lists the built-in roles
# (agent, administrator) together with the account custom roles, so a custom
# role can be assigned from the same select. Custom roles are submitted as
# `custom_<id>` and resolved by SuperAdmin::AccountUsersController.
class AccountRoleField < Administrate::Field::Base
  CUSTOM_PREFIX = 'custom_'.freeze

  def to_s
    custom_role&.name || data
  end

  def selected_option
    custom_role ? "#{CUSTOM_PREFIX}#{custom_role.id}" : data
  end

  # Built-in roles first, then custom roles grouped by account. When the form
  # already knows its account (account page), only that account's roles show.
  def grouped_options
    groups = [['Default', AccountUser.roles.keys.map { |role| [role, role] }]]
    custom_roles.group_by(&:account).each do |account, roles|
      groups << ["Custom roles - #{account.name}", roles.map { |role| [role.name, "#{CUSTOM_PREFIX}#{role.id}"] }]
    end
    groups
  end

  private

  def custom_role
    resource.try(:custom_role)
  end

  def custom_roles
    return [] unless defined?(CustomRole)

    scope = CustomRole.includes(:account).order(:account_id, :name)
    resource&.account_id ? scope.where(account_id: resource.account_id) : scope
  end
end
