class CampaignPolicy < ApplicationPolicy
  def index?
    administrator_or_custom_role_permission?('campaign_manage')
  end

  def update?
    administrator_or_custom_role_permission?('campaign_manage')
  end

  def show?
    administrator_or_custom_role_permission?('campaign_manage')
  end

  def create?
    administrator_or_custom_role_permission?('campaign_manage')
  end

  def destroy?
    administrator_or_custom_role_permission?('campaign_manage')
  end

  def ai_generate?
    administrator_or_custom_role_permission?('campaign_manage')
  end

  def clone?
    administrator_or_custom_role_permission?('campaign_manage')
  end

  def results?
    administrator_or_custom_role_permission?('campaign_manage')
  end

  def retry_failed?
    administrator_or_custom_role_permission?('campaign_manage')
  end

  def whatsapp_chats?
    administrator_or_custom_role_permission?('campaign_manage')
  end

  def whatsapp_chat_permissions?
    administrator_or_custom_role_permission?('campaign_manage')
  end

  def check_numbers?
    administrator_or_custom_role_permission?('campaign_manage')
  end

  def audience_preview?
    administrator_or_custom_role_permission?('campaign_manage')
  end
end
