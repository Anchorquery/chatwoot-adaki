class Adaki::AuditLogEntry < ApplicationRecord
  self.table_name = 'adaki_audit_log_entries'

  belongs_to :account
  belongs_to :user, optional: true

  validates :action, :hash_chain, :recorded_at, presence: true

  # Append-only — destructive operations forbidden at model layer.
  def readonly?
    persisted?
  end

  before_destroy { raise ActiveRecord::ReadOnlyRecord, 'Adaki::AuditLogEntry is append-only' }

  scope :for_account, ->(account) { where(account_id: account.id) }

  # Iterates by primary key ASC. AuditLogger advisory lock guarantees
  # id order == insertion order == chain order, so find_each (which only
  # supports order :asc on PK) is safe here.
  def self.verify_chain!(account)
    previous_hash = nil
    for_account(account).find_each(order: :asc) do |entry|
      raise "Broken chain at #{entry.id}: previous_hash mismatch" if entry.previous_hash != previous_hash

      expected = Adaki::AuditLogger.compute_hash(
        previous_hash: previous_hash,
        account_id: entry.account_id,
        user_id: entry.user_id,
        action: entry.action,
        auditable_type: entry.auditable_type,
        auditable_id: entry.auditable_id,
        payload: entry.payload,
        recorded_at: entry.recorded_at
      )
      raise "Tampered entry at #{entry.id}: hash mismatch" if entry.hash_chain != expected

      previous_hash = entry.hash_chain
    end
    true
  end
end
