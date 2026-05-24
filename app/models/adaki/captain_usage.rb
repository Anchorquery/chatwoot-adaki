class Adaki::CaptainUsage < ApplicationRecord
  self.table_name = 'adaki_captain_usages'

  belongs_to :account

  validates :period, presence: true
  validates :account_id, uniqueness: { scope: :period }

  def self.current_for(account)
    find_or_create_by!(account_id: account.id, period: Date.current.beginning_of_month)
  end
end
