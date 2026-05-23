class Adaki::CampaignApprovalPolicy < ApplicationPolicy
  def index?
    @account_user.administrator?
  end

  def create?
    @account_user.administrator?
  end

  def approve?
    @account_user.administrator?
  end

  def reject?
    @account_user.administrator?
  end
end
