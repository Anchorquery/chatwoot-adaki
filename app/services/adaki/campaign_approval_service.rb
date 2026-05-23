class Adaki::CampaignApprovalService
  class ApprovalRequired < StandardError; end
  class NotApproved < StandardError; end

  def initialize(campaign)
    @campaign = campaign
  end

  def request_approval!(requested_by:, recipient_count: nil)
    raise 'Campaign already approved' if @campaign.approval_status == 'approved'
    raise 'Campaign already has a pending approval' if Adaki::CampaignApproval
                                                       .exists?(campaign_id: @campaign.id, status: 'pending')

    approval = Adaki::CampaignApproval.create!(
      campaign: @campaign,
      account: @campaign.account,
      requested_by: requested_by,
      requested_at: Time.current,
      recipient_count: recipient_count
    )
    @campaign.update!(approval_status: 'pending')

    Adaki::AuditLogger.log(
      account: @campaign.account,
      user: requested_by,
      action: 'campaign.approval.requested',
      auditable: @campaign,
      payload: { recipient_count: recipient_count }
    )
    approval
  end

  def approve!(approver:, note: nil)
    approval = current_pending!
    approval.approve!(approver, note)
    @campaign.update!(approval_status: 'approved')

    Adaki::AuditLogger.log(
      account: @campaign.account,
      user: approver,
      action: 'campaign.approval.approved',
      auditable: @campaign,
      payload: { note: note }
    )
    approval
  end

  def reject!(approver:, note: nil)
    approval = current_pending!
    approval.reject!(approver, note)
    @campaign.update!(approval_status: 'rejected')

    Adaki::AuditLogger.log(
      account: @campaign.account,
      user: approver,
      action: 'campaign.approval.rejected',
      auditable: @campaign,
      payload: { note: note }
    )
    approval
  end

  def ensure_approved!
    return unless @campaign.requires_approval?

    raise NotApproved, "Campaign #{@campaign.id} not approved" unless @campaign.approval_status == 'approved'
  end

  private

  def current_pending!
    approval = Adaki::CampaignApproval
               .where(campaign_id: @campaign.id, status: 'pending')
               .order(:created_at).last
    raise 'No pending approval found' if approval.blank?

    approval
  end
end
