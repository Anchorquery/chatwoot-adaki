# Caps how many tokens a Captain reply may generate.
#
# Generation is sequential: a 900-token answer takes roughly three times as
# long to produce as a 300-token one. Captain is a support bot answering from
# FAQs, so long replies are almost always the model padding — and on WhatsApp
# they read badly on top of being slow. The cap is a safety net; the prompt
# (see prompts/snippets/formatting.liquid) is what actually keeps replies short.
#
# Shape per provider, deep-merged into the request payload by RubyLLM
# (Provider#complete -> Utils.deep_merge(payload, params)).
module Llm::OutputLimit
  module_function

  # Generous enough that a legitimate catalogue answer (~350 tokens in the
  # production sample) is never truncated mid-sentence, low enough to stop a
  # model that decided to write an essay.
  DEFAULT_MAX_TOKENS = 800

  # Gemini counts thinking tokens against maxOutputTokens, so a model left
  # with a thinking budget needs that budget on top of the visible answer or
  # it can burn the whole allowance thinking and return an empty reply.
  def params_for(provider:, model:, max_tokens: DEFAULT_MAX_TOKENS, thinking_params: {})
    return {} if max_tokens.blank? || max_tokens.to_i <= 0

    max_tokens = max_tokens.to_i
    case provider.to_s
    when 'gemini', 'google'
      { generationConfig: { maxOutputTokens: max_tokens + gemini_thinking_budget(thinking_params) } }
    when 'openai'
      { openai_max_tokens_key(model) => max_tokens }
    when 'deepseek', 'anthropic'
      { max_tokens: max_tokens }
    else
      {}
    end
  end

  def gemini_thinking_budget(thinking_params)
    budget = thinking_params.to_h.dig(:generationConfig, :thinkingConfig, :thinkingBudget)
    budget.to_i.clamp(0, 4096)
  end

  # Reasoning models rejected `max_tokens` in favour of
  # `max_completion_tokens`, which also covers the reasoning tokens.
  def openai_max_tokens_key(model)
    model.to_s.match?(/\A(?:gpt-5|o[134])/) ? :max_completion_tokens : :max_tokens
  end
end
