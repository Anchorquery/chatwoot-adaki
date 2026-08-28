class Platform::Credentials::RevalidationJob < ApplicationJob
  queue_as :low

  # Keeps Platform::Credential#status/#metadata truthful without waiting for
  # someone to hit a broken key in production first — see O3 in
  # docs/adaki/captain-remediacion.md (a credential's status was already
  # :revoked but its metadata['validation'] still said "active" from the last
  # time anyone checked, months earlier — nothing ever re-validated it).
  # Only active/invalid_credential get re-checked: a :revoked credential was
  # turned off by a human on purpose and shouldn't be silently reactivated by
  # an automated job just because the key happens to work again.
  REVALIDATED_STATUSES = %w[active invalid_credential].freeze

  def perform
    failures = []

    Platform::Credential.where(status: REVALIDATED_STATUSES).find_each do |credential|
      Platform::CredentialManager.validate!(credential: credential)
    rescue StandardError => e
      Rails.logger.warn "[Platform::Credentials::RevalidationJob] credential=#{credential.id} FAIL #{e.message}"
      failures << { credential_id: credential.id, error: e.message }
      ChatwootExceptionTracker.new(e, account: credential.account).capture_exception
    end

    return if failures.empty?

    raise "Credential revalidation failed for #{failures.size} credentials: #{failures.pluck(:credential_id).join(', ')}"
  end
end
