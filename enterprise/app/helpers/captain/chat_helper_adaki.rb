module Captain::ChatHelperAdaki
  def request_chat_completion
    account = adaki_resolve_account
    Adaki::CaptainUsageTracker.enforce_limit!(account) if account

    response = super

    if account
      tokens = adaki_extract_token_counts(response)
      Adaki::CaptainUsageTracker.record!(
        account: account,
        user: nil,
        feature: feature_name,
        input_tokens: tokens[:input],
        output_tokens: tokens[:output],
        assistant_id: @assistant&.id
      )
    end

    response
  end

  private

  def adaki_resolve_account
    @account || @assistant&.account
  end

  def adaki_extract_token_counts(response)
    return { input: 0, output: 0 } unless response.respond_to?(:input_tokens) || response.respond_to?(:usage)

    if response.respond_to?(:input_tokens)
      { input: response.input_tokens.to_i, output: response.output_tokens.to_i }
    else
      usage = response.usage || {}
      { input: usage[:prompt_tokens].to_i, output: usage[:completion_tokens].to_i }
    end
  end
end

Captain::ChatHelper.prepend(Captain::ChatHelperAdaki)
