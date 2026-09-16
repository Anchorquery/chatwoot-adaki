# Second layer for Captain::Assistant::AgentRunnerService::PROMISE_ONLY_PATTERNS
# (docs/adaki/captain-plan-latencia-2026-09.md fase 5.2, komunikia's
# announce-guard.ts pattern): the regex is a cheap, over-inclusive first pass
# that can misfire on a legitimate reply that merely mentions "un momento" or
# similar as part of a real answer. This runs only on what the regex already
# flagged, and gives the final yes/no on whether the extra retry turn (and its
# tokens/latency) is actually worth spending.
class Captain::Llm::PromiseOnlyJudgeService < Captain::BaseTaskService
  # Captain::BaseTaskService.inherited prepends Enterprise::Captain::BaseTaskService,
  # whose #perform takes no arguments and calls a bare `super` — every
  # subclass's own #perform must be zero-arg, with inputs passed at
  # construction instead (same shape as Captain::LabelSuggestionService).
  pattr_initialize [:account!, :reply_text!, { conversation_display_id: nil }]

  RETRY_VERDICT = 'RETRY'.freeze

  # @return [Boolean] true = retry the turn, false = the draft is fine as-is
  def perform
    response = make_api_call(
      model: resolved_generator_model,
      messages: [
        { role: 'system', content: prompt_from_file('promise_only_judge') },
        { role: 'user', content: reply_text }
      ]
    )
    # Fail open on any provider/config error: keep today's regex-only
    # behavior (retry) rather than silently swallowing a real promise-only
    # reply because the judge itself couldn't run.
    return true if response[:error].present?

    response[:message].to_s.strip.upcase.start_with?(RETRY_VERDICT)
  end

  private

  # Routes through the account's cheap/utility model (falls back to whatever
  # 'assistant' would resolve to if no utility model is configured) rather
  # than the assistant's main model — this is a one-word classification, not
  # a customer-facing reply.
  def event_name
    'utility'
  end

  def build_follow_up_context?
    false
  end

  # An internal quality gate on a turn that has not been sent yet — must not
  # consume a separate Captain response credit or be blocked by the
  # customer-facing quota (that accounting already happens once, for the
  # actual reply, elsewhere).
  def counts_toward_usage?
    false
  end
end
