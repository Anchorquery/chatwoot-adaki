module Enterprise::Concerns::AccountUser
  extend ActiveSupport::Concern

  included do
    belongs_to :custom_role, optional: true
    belongs_to :agent_capacity_policy, optional: true

    validate :custom_role_belongs_to_account
    before_save :reconcile_role_with_custom_role
  end

  private

  def custom_role_belongs_to_account
    return if custom_role.blank? || custom_role.account_id == account_id

    errors.add(:custom_role, 'must belong to the same account')
  end

  # A custom role layers permissions on top of the agent role, while an
  # administrator already has full access. Keep both columns consistent so an
  # administrator never keeps admin access after being given a custom role:
  # promoting to administrator drops the custom role, anything else with a
  # custom role is an agent.
  def reconcile_role_with_custom_role
    return if custom_role_id.blank?

    if will_save_change_to_role? && administrator?
      self.custom_role_id = nil
    else
      self.role = :agent
    end
  end
end
