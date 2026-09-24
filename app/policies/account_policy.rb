class AccountPolicy < ApplicationPolicy
  def show?
    @account_user.administrator? || @account_user.agent?
  end

  def cache_keys?
    @account_user.administrator? || @account_user.agent?
  end

  def limits?
    @account_user.administrator? || @account_user.agent?
  end

  def update?
    @account_user.administrator?
  end

  def update_captain_preferences?
    administrator_or_custom_role_permission?('captain_manage')
  end

  def manage_platform_credentials?
    administrator_or_custom_role_permission?('captain_manage')
  end

  def update_active_at?
    true
  end

  def subscription?
    @account_user.administrator?
  end

  def checkout?
    @account_user.administrator?
  end

  def toggle_deletion?
    @account_user.administrator?
  end

  def topup_checkout?
    @account_user.administrator?
  end
end
