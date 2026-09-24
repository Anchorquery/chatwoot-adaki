class AddSidebarProfileToCustomRoles < ActiveRecord::Migration[7.0]
  def change
    add_column :custom_roles, :sidebar_profile, :string
  end
end
