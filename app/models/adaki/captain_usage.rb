class Adaki::CaptainUsage < ApplicationRecord
  self.table_name = 'adaki_captain_usages'

  belongs_to :account

  validates :period, presence: true

  # No uniqueness validation here on purpose (Rails' own guidance for
  # create_or_find_by!): the unique DB index on [account_id, period] (see
  # db/migrate/20260523000000_create_adaki_captain_usage.rb) is what
  # actually enforces this. A validates :account_id, uniqueness: ... here
  # would run as part of every create! attempt below — including the
  # ordinary, extremely common case where the current period's row already
  # exists (current_for is called on essentially every Captain response) —
  # and raise ActiveRecord::RecordInvalid *before* create_or_find_by! ever
  # gets a chance to recover, which only rescues the DB-level
  # RecordNotUnique. Caught by running the real spec suite against a real
  # Postgres for the first time this session (2026-08-28) — every
  # CaptainUsage-touching spec failed with "Account has already been taken"
  # the moment two examples shared the current month's period.

  # create_or_find_by! (not find_or_create_by!): under concurrent Captain
  # responses for the same account, two workers can both miss the initial
  # find and race to create — the unique index on [account_id, period]
  # then makes one INSERT fail, and create_or_find_by! recovers from that
  # by re-querying instead of raising ActiveRecord::RecordNotUnique.
  def self.current_for(account)
    create_or_find_by!(account_id: account.id, period: Date.current.beginning_of_month)
  end
end
