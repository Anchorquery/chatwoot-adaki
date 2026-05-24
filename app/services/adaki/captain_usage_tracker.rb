class Adaki::CaptainUsageTracker
  class LimitExceeded < StandardError; end

  def self.enforce_limit!(account)
    return if account.nil?

    limit = account.respond_to?(:adaki_captain_monthly_limit) ? account.adaki_captain_monthly_limit : nil
    return if limit.blank? || limit.zero?

    usage = Adaki::CaptainUsage.current_for(account)
    return if usage.request_count < limit

    raise LimitExceeded, "Captain monthly limit (#{limit}) reached for account #{account.id}"
  end

  def self.record!(account:, user: nil, feature:, input_tokens: 0, output_tokens: 0, assistant_id: nil)
    return if account.nil?

    Adaki::CaptainUsage.transaction do
      usage = Adaki::CaptainUsage.current_for(account)
      Adaki::CaptainUsage.where(id: usage.id).update_all(
        'request_count = request_count + 1, ' \
        "input_tokens = input_tokens + #{input_tokens.to_i}, " \
        "output_tokens = output_tokens + #{output_tokens.to_i}, " \
        'updated_at = NOW()'
      )
    end

    Adaki::AuditLogger.log(
      account: account,
      user: user,
      action: "captain.#{feature}.invocation",
      payload: {
        assistant_id: assistant_id,
        input_tokens: input_tokens,
        output_tokens: output_tokens
      }
    )
  end
end
