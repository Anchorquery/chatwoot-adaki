module Enterprise::AccountUser
  def permissions
    return super if custom_role.blank?

    (custom_role.permissions + custom_role.profile_permissions + ['custom_role']).uniq
  end
end
