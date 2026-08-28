module Captain::ChatHelperAdaki
  def request_chat_completion
    account = adaki_resolve_account
    Adaki::CaptainUsageTracker.enforce_limit!(account) if account

    response = super

    if account
      # Real token counts, not a guess: llm_usage (Captain::ChatHelper) accumulates
      # from chat.on_end_message across every LLM call this response made, including
      # tool-call round-trips. `response` here is the already-parsed JSON hash
      # (build_response's return value) and never carried usage data — reading it
      # for tokens is what made V1's Adaki accounting always log 0/0. See
      # docs/adaki/captain-remediacion.md §Fase 4, C10.
      usage = llm_usage
      Adaki::CaptainUsageTracker.record!(
        account: account,
        user: nil,
        feature: feature_name,
        input_tokens: usage[:input],
        output_tokens: usage[:output],
        assistant_id: @assistant&.id
      )
    end

    response
  end

  private

  def adaki_resolve_account
    @account || @assistant&.account
  end
end

Captain::ChatHelper.prepend(Captain::ChatHelperAdaki)
