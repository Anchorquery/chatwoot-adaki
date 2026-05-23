class Api::V1::Accounts::Campaigns::ApprovalsController < Api::V1::Accounts::BaseController
  before_action :campaign
  before_action -> { check_authorization(Adaki::CampaignApproval) }

  def index
    @approvals = Adaki::CampaignApproval.where(campaign_id: @campaign.id).order(created_at: :desc)
    render json: @approvals
  end

  def create
    approval = Adaki::CampaignApprovalService.new(@campaign).request_approval!(
      requested_by: Current.user,
      recipient_count: params[:recipient_count]
    )
    render json: approval, status: :created
  end

  def approve
    approval = Adaki::CampaignApprovalService.new(@campaign).approve!(approver: Current.user, note: params[:note])
    render json: approval
  end

  def reject
    approval = Adaki::CampaignApprovalService.new(@campaign).reject!(approver: Current.user, note: params[:note])
    render json: approval
  end

  private

  def campaign
    @campaign ||= Current.account.campaigns.find_by!(display_id: params[:campaign_id])
  end
end
