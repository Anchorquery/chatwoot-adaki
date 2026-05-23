require 'digest'

class Adaki::AuditLogger
  def self.log(account:, action:, user: nil, auditable: nil, payload: {})
    new(account: account, user: user, action: action, auditable: auditable, payload: payload).call
  end

  def self.compute_hash(previous_hash:, account_id:, user_id:, action:, auditable_type:, auditable_id:, payload:, recorded_at:)
    canonical = [
      previous_hash.to_s,
      account_id.to_i,
      user_id.to_i,
      action.to_s,
      auditable_type.to_s,
      auditable_id.to_i,
      canonical_json(payload),
      recorded_at.utc.iso8601(6)
    ].join('|')
    Digest::SHA256.hexdigest(canonical)
  end

  # Order-stable JSON: keys sorted recursively so re-serialization after DB
  # round-trip (jsonb -> Hash) produces identical bytes for verify_chain!.
  def self.canonical_json(obj)
    JSON.generate(canonicalize(obj))
  end

  def self.canonicalize(obj)
    case obj
    when Hash
      obj.each_with_object({}) { |(k, v), h| h[k.to_s] = canonicalize(v) }
         .sort.to_h
    when Array
      obj.map { |e| canonicalize(e) }
    else
      obj
    end
  end

  def initialize(account:, action:, user: nil, auditable: nil, payload: {})
    @account = account
    @action = action
    @user = user
    @auditable = auditable
    @payload = payload || {}
  end

  def call
    Adaki::AuditLogEntry.transaction do
      # Serialize per-account append to keep hash chain monotonic under concurrency.
      Adaki::AuditLogEntry.connection.execute(
        ActiveRecord::Base.sanitize_sql_array(['SELECT pg_advisory_xact_lock(?)', advisory_key])
      )

      previous = Adaki::AuditLogEntry.for_account(@account).order(:id).last
      recorded_at = Time.current
      hash_chain = self.class.compute_hash(
        previous_hash: previous&.hash_chain,
        account_id: @account.id,
        user_id: @user&.id,
        action: @action,
        auditable_type: @auditable&.class&.name,
        auditable_id: @auditable&.id,
        payload: @payload,
        recorded_at: recorded_at
      )

      Adaki::AuditLogEntry.create!(
        account: @account,
        user: @user,
        action: @action,
        auditable_type: @auditable&.class&.name,
        auditable_id: @auditable&.id,
        payload: @payload,
        previous_hash: previous&.hash_chain,
        hash_chain: hash_chain,
        recorded_at: recorded_at
      )
    end
  end

  private

  # Compress account_id to bigint range for pg_advisory_xact_lock.
  def advisory_key
    Zlib.crc32("adaki_audit_chain_#{@account.id}")
  end
end
