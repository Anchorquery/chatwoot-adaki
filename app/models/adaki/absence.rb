class Adaki::Absence < ApplicationRecord
  self.table_name = 'adaki_absences'

  STATUSES = %w[scheduled active ended cancelled].freeze

  belongs_to :account
  belongs_to :user
  belongs_to :coverage_user, class_name: 'User', optional: true

  validates :start_at, :end_at, presence: true
  validates :status, inclusion: { in: STATUSES }
  validate :end_after_start
  validate :user_belongs_to_account
  validate :coverage_user_belongs_to_account

  scope :active_at, ->(time = Time.current) { where('start_at <= ? AND end_at >= ?', time, time) }
  scope :for_user, ->(user) { where(user_id: user.id) }

  def active?
    status == 'active' || (status == 'scheduled' && start_at <= Time.current && end_at >= Time.current)
  end

  private

  def end_after_start
    return if start_at.blank? || end_at.blank?

    errors.add(:end_at, 'must be after start_at') if end_at <= start_at
  end

  def coverage_user_belongs_to_account
    return if coverage_user_id.blank?
    return if account.blank?
    return if account.users.exists?(id: coverage_user_id)

    errors.add(:coverage_user_id, 'must belong to the same account')
  end

  def user_belongs_to_account
    return if user_id.blank? || account.blank?
    return if account.users.exists?(id: user_id)

    errors.add(:user_id, 'must belong to the same account')
  end
end
