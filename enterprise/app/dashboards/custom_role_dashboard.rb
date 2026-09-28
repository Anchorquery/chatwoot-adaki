require 'administrate/base_dashboard'

class CustomRoleDashboard < Administrate::BaseDashboard
  ATTRIBUTE_TYPES = {
    id: Field::Number,
    account: Field::BelongsToSearch.with_options(class_name: 'Account', searchable: true, searchable_field: [:name, :id], order: 'id DESC'),
    name: Field::String,
    description: Field::String,
    permissions: ArrayCheckboxesField.with_options(collection: CustomRole::PERMISSIONS,
                                                   i18n_scope: 'super_admin.custom_roles.permissions'),
    sidebar_profile: SidebarProfileField.with_options(collection: CustomRole::SIDEBAR_PROFILES),
    account_users: Field::HasMany,
    created_at: Field::DateTime,
    updated_at: Field::DateTime
  }.freeze

  COLLECTION_ATTRIBUTES = %i[
    id
    name
    account
    sidebar_profile
    permissions
  ].freeze

  SHOW_PAGE_ATTRIBUTES = %i[
    id
    account
    name
    description
    sidebar_profile
    permissions
    account_users
    created_at
    updated_at
  ].freeze

  FORM_ATTRIBUTES = %i[
    account
    name
    description
    sidebar_profile
    permissions
  ].freeze

  COLLECTION_FILTERS = {}.freeze

  def display_resource(custom_role)
    custom_role.name
  end
end
