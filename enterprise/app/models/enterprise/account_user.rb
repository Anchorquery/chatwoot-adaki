module Enterprise::AccountUser
  def permissions
    return super if custom_role.blank?

    (custom_role.effective_permissions + ['custom_role']).uniq
  end
end
