class Adaki::CampaignApprovalPolicy < ApplicationPolicy
  def index?
    administrator_or_custom_role_permission?('campaign_manage')
  end

  def create?
    administrator_or_custom_role_permission?('campaign_manage')
  end

  def approve?
    administrator_or_custom_role_permission?('campaign_approve')
  end

  def reject?
    administrator_or_custom_role_permission?('campaign_approve')
  end
end
