# Caches Platform::Models::Resolver's result per account for a few minutes.
# Resolver scans every enabled/synced platform_credential_model row for the
# account (up to ~170 rows on a multi-provider account, per docs/adaki/
# captain-plan-latencia-2026-09.md fase 3.6) on EVERY Captain turn, for a
# result that only changes when someone edits credentials/models in the
# Super Admin UI. Never the source of truth — a cache-read failure (Redis
# down, corrupt entry) falls back to resolving uncached rather than breaking
# the turn.
module Platform::Models::ResolutionCache
  TTL = 5.minutes
  VERSION_PREFIX = 'captain:model_resolution:version'.freeze
  ENTRY_PREFIX = 'captain:model_resolution:entry'.freeze

  # Distinct from a legitimately-cached `nil` result (an account with no
  # usable model, which IS worth caching) — returned by #decode when the
  # entry itself cannot be trusted (bad JSON, or a credential_id that no
  # longer resolves because the credential was deleted since caching), so
  # #fetch knows to recompute instead of handing back a hollow result.
  MISS = :resolution_cache_miss

  module_function

  # `cache_params` identifies the call shape (feature/kind/preferred_slug/
  # allow_credential_only) — anything not covered by it (e.g. exclude_slugs
  # for a failover retry) must not go through this method at all; the caller
  # decides that, not this cache.
  def fetch(account_id, cache_params)
    key = entry_key(account_id, cache_params)
    raw = Redis::Alfred.get(key)
    decoded = raw.present? ? decode(raw) : MISS
    return decoded unless decoded == MISS

    result = yield
    write(key, result)
    result
  rescue StandardError => e
    Rails.logger.warn("[Platform::Models::ResolutionCache] read failed, resolving uncached: #{e.class}: #{e.message}")
    yield
  end

  # Bumping the account's version, rather than deleting the specific entries,
  # invalidates every cached (feature, kind, preferred_slug, ...) combination
  # for that account at once without having to enumerate them.
  def bump(account_id)
    return if account_id.blank?

    Redis::Alfred.incr(version_key(account_id))
  rescue StandardError => e
    Rails.logger.warn("[Platform::Models::ResolutionCache] invalidation failed: #{e.class}: #{e.message}")
  end

  def entry_key(account_id, cache_params)
    "#{ENTRY_PREFIX}:#{account_id}:#{version(account_id)}:#{Digest::SHA256.hexdigest(cache_params.to_s)}"
  end

  def version(account_id)
    Redis::Alfred.get(version_key(account_id)) || 0
  rescue StandardError
    0
  end

  def version_key(account_id)
    "#{VERSION_PREFIX}:#{account_id}"
  end

  def write(key, result)
    Redis::Alfred.set(key, encode(result), ex: TTL.to_i)
  rescue StandardError => e
    Rails.logger.warn("[Platform::Models::ResolutionCache] write failed: #{e.class}: #{e.message}")
  end

  # Stores only the credential id, not the AR object — decode re-loads it, so
  # a credential deleted since caching is a clean miss instead of a stale
  # reference.
  def encode(result)
    return 'null' if result.nil?

    { credential_id: result[:credential]&.id, model_slug: result[:model_slug], source: result[:source] }.to_json
  end

  def decode(raw)
    return nil if raw == 'null'

    parsed = JSON.parse(raw).with_indifferent_access
    credential_id = parsed[:credential_id]
    credential = credential_for(credential_id)
    return MISS if credential_id.present? && credential.nil?

    { credential: credential, model_slug: parsed[:model_slug], source: parsed[:source]&.to_sym }
  rescue JSON::ParserError
    MISS
  end

  def credential_for(credential_id)
    return nil if credential_id.blank?

    Platform::Credential.find_by(id: credential_id)
  end
end
