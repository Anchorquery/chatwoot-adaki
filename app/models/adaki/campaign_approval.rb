class Adaki::CampaignApproval < ApplicationRecord
  self.table_name = 'adaki_campaign_approvals'

  STATUSES = %w[pending approved rejected cancelled].freeze

  belongs_to :campaign
  belongs_to :account
  belongs_to :requested_by, class_name: 'User'
  belongs_to :approved_by, class_name: 'User', optional: true

  validates :status, inclusion: { in: STATUSES }
  validates :requested_at, presence: true
  validate :approver_distinct_from_requester

  scope :pending, -> { where(status: 'pending') }

  def approve!(user, note = nil)
    update!(status: 'approved', approved_by: user, decided_at: Time.current, decision_note: note)
  end

  def reject!(user, note = nil)
    update!(status: 'rejected', approved_by: user, decided_at: Time.current, decision_note: note)
  end

  private

  def approver_distinct_from_requester
    return if approved_by_id.blank?
    return if approved_by_id != requested_by_id

    errors.add(:approved_by_id, 'must be different from requester')
  end
end
