# Stops Captain from repeatedly attempting an LLM call with a credential that
# has just failed with a `configuration`-classified error (see
# Captain::FailurePolicy) — a dead/revoked API key, an exhausted billing
# quota. Without this, every incoming message on a broken account pays the
# full cost of a doomed attempt (provider round-trip, a fresh private note on
# every single message, exception-tracker noise) instead of failing fast.
#
# Keyed by account, not by Platform::Credential row: an account may be using
# an explicit per-account credential OR the legacy global InstallationConfig
# fallback (see Llm::Config), and either way it's the account whose Captain
# traffic needs to stop hammering a dead key. See
# docs/adaki/captain-remediacion.md §2b.
#
# Self-healing by design (no dependency on a revalidation job existing): the
# open state carries its own TTL, so the very next attempt after the cooldown
# is allowed through normally, same as the classic circuit-breaker half-open
# step — succeed and the circuit closes, fail again and the cooldown restarts.
# A future credential-revalidation job can still call `close!` explicitly the
# moment it confirms a rotated key works, without waiting out the cooldown.
module Captain::CredentialCircuitBreaker
  FAILURE_THRESHOLD = 3
  FAILURE_WINDOW = 10.minutes.to_i
  OPEN_COOLDOWN = 10.minutes.to_i

  class << self
    def open?(account)
      Redis::Alfred.exists?(open_key(account))
    end

    # Call after a `configuration`-classified failure. Opens the circuit (and
    # notifies once, not on every subsequent failure) once FAILURE_THRESHOLD
    # is reached within FAILURE_WINDOW.
    def record_failure!(account)
      key = failure_count_key(account)
      count = Redis::Alfred.incr(key)
      Redis::Alfred.expire(key, FAILURE_WINDOW) if count == 1

      return if count < FAILURE_THRESHOLD

      open_circuit!(account, count)
    end

    # Call after ANY successful response (not just a recovered one) — keeps a
    # healthy credential's failure count from ever accumulating toward the
    # threshold from unrelated, sporadic failures.
    def record_success!(account)
      close!(account)
    end

    # Explicit close, independent of the cooldown timer — for a future
    # credential-revalidation job to call the moment it confirms a fix.
    def close!(account)
      Redis::Alfred.delete(failure_count_key(account))
      Redis::Alfred.delete(open_key(account))
    end

    private

    def open_circuit!(account, failure_count)
      newly_opened = !open?(account)
      Redis::Alfred.set(open_key(account), Time.current.to_i, ex: OPEN_COOLDOWN)

      notify_admin(account, failure_count) if newly_opened
    end

    def notify_admin(account, failure_count)
      error = StandardError.new(
        "Captain: circuito de credencial abierto para account=#{account.id} " \
        "tras #{failure_count} fallos de configuración en #{FAILURE_WINDOW / 60} min"
      )
      ChatwootExceptionTracker.new(error, account: account).capture_exception
      Rails.logger.error(
        "[CAPTAIN][CredentialCircuitBreaker] Circuit opened for account=#{account.id} after #{failure_count} failures"
      )
    end

    def failure_count_key(account)
      "CAPTAIN::CIRCUIT::ACCOUNT::#{account.id}::FAILURES"
    end

    def open_key(account)
      "CAPTAIN::CIRCUIT::ACCOUNT::#{account.id}::OPEN"
    end
  end
end
