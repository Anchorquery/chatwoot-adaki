# Classifies a Captain LLM-call failure so the caller can react appropriately,
# instead of treating every StandardError as an identical "hand off to a
# human" event (the previous behavior — see docs/adaki/captain-remediacion.md
# §2). A dead/revoked API key and a transient provider hiccup produced the
# exact same customer-facing message and left no trace of which one actually
# happened; that ambiguity is what turned a five-minute credential fix into a
# multi-day investigation in production.
#
# Classification is provider-body-aware where the exception class alone is
# ambiguous:
#   - Gemini reports an invalid API key as HTTP 400 (`API_KEY_INVALID`), which
#     RubyLLM maps to the same BadRequestError as any other malformed request.
#   - OpenAI reports both rate-limiting and exhausted billing quota as HTTP
#     429 (`insufficient_quota` in the body for the latter), both mapped to
#     the same RateLimitError. One is worth retrying, the other never will
#     succeed no matter how many times you ask.
# See docs/adaki/captain-referencias-tecnicas.md §3 for the source (Gemini/
# OpenAI official error docs) and §1 for RubyLLM's exact status→exception map.
module Captain::FailurePolicy
  # Permanent, not the LLM's fault: a broken/misconfigured credential, an
  # exhausted billing quota, or Adaki's own monthly cap. Retrying changes
  # nothing — hand off, but leave a private note with the real cause instead
  # of presenting it identically to a legitimate handoff decision.
  CONFIGURATION = :configuration
  # Temporary, the provider's fault: rate limiting, a 5xx, or the connection
  # dropping. Worth retrying with backoff — NOT a reason to hand off, and
  # RubyLLM/Faraday have already exhausted their own short internal retry
  # budget by the time this exception reaches us (see referencias-tecnicas.md
  # §1), so this is a second, coarser retry layer at the job level.
  TRANSIENT = :transient
  # The prompt itself doesn't fit — retrying identically will fail identically
  # (unlike TRANSIENT). Hands off like CONFIGURATION, but it isn't a
  # credential problem, so it must never count toward that circuit.
  BUDGET = :budget
  # Adaki's own monthly quota (independent of the upstream provider's
  # quota/billing, see docs/adaki/captain-limits.md Capa 2).
  LIMIT_ADAKI = :limit_adaki
  # Anything not recognized above. Handled the same as CONFIGURATION/BUDGET
  # (handoff, no retry) since an unrecognized failure mode should fail safe
  # rather than be silently retried.
  UNKNOWN = :unknown

  CONFIGURATION_ERROR_CLASSES = [
    RubyLLM::ConfigurationError,
    RubyLLM::UnauthorizedError,
    RubyLLM::PaymentRequiredError,
    RubyLLM::ForbiddenError
  ].freeze

  TRANSIENT_ERROR_CLASSES = [
    RubyLLM::RateLimitError,
    RubyLLM::ServerError,
    RubyLLM::ServiceUnavailableError,
    RubyLLM::OverloadedError,
    Faraday::TimeoutError,
    Faraday::ConnectionFailed,
    Timeout::Error
  ].freeze

  GEMINI_INVALID_KEY_MARKER = 'API_KEY_INVALID'.freeze
  OPENAI_INSUFFICIENT_QUOTA_MARKER = 'insufficient_quota'.freeze

  # Wraps a TRANSIENT-classified error so Captain::Conversation::ResponseBuilderJob's
  # `retry_on` can match a single exception class for its job-level retry,
  # regardless of which underlying provider/RubyLLM exception triggered it.
  class TransientProviderError < StandardError; end

  module_function

  def classify(error)
    return TRANSIENT if error.is_a?(TransientProviderError)
    return LIMIT_ADAKI if adaki_limit_exceeded?(error)
    return BUDGET if budget_error?(error)
    return CONFIGURATION if configuration_error?(error)
    return TRANSIENT if transient_error?(error)

    UNKNOWN
  end

  def configuration?(error)
    classify(error) == CONFIGURATION
  end

  def transient?(error)
    classify(error) == TRANSIENT
  end

  def budget?(error)
    classify(error) == BUDGET
  end

  def limit_adaki?(error)
    classify(error) == LIMIT_ADAKI
  end

  def adaki_limit_exceeded?(error)
    error.is_a?(Adaki::CaptainUsageTracker::LimitExceeded)
  end

  def budget_error?(error)
    error.is_a?(RubyLLM::ContextLengthExceededError)
  end

  def configuration_error?(error)
    return true if CONFIGURATION_ERROR_CLASSES.any? { |klass| error.is_a?(klass) }
    return true if gemini_invalid_api_key?(error)
    return true if openai_insufficient_quota?(error)

    false
  end

  def transient_error?(error)
    TRANSIENT_ERROR_CLASSES.any? { |klass| error.is_a?(klass) }
  end

  # RubyLLM's ErrorMiddleware passes the response body through unparsed (see
  # referencias-tecnicas.md §1), so this checks for the provider-specific
  # marker as a raw substring rather than parsing JSON — simpler, and doesn't
  # break if the body is truncated or shaped unexpectedly.
  def gemini_invalid_api_key?(error)
    return false unless error.is_a?(RubyLLM::BadRequestError)

    error_response_body(error).include?(GEMINI_INVALID_KEY_MARKER)
  end

  def openai_insufficient_quota?(error)
    return false unless error.is_a?(RubyLLM::RateLimitError)

    error_response_body(error).include?(OPENAI_INSUFFICIENT_QUOTA_MARKER)
  end

  def error_response_body(error)
    return '' unless error.respond_to?(:response) && error.response

    response = error.response
    body = response.respond_to?(:body) ? response.body : response
    body.to_s
  rescue StandardError
    ''
  end
end
