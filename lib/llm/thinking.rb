# Turns an assistant's "reasoning level" setting into the provider-specific
# request parameters that cap (or disable) the model's internal reasoning.
#
# Why this exists: Gemini 2.5 models reason before answering and those
# thinking tokens are billed at the output rate and count against the output
# limit. Neither RubyLLM nor the ai-agents gem sends a thinkingConfig unless
# something explicitly asks for one, so by default Gemini applies its own
# dynamic budget with no ceiling. In production (conversation 309,
# 2026-09-04) that produced a reply made of thought parts only — RubyLLM
# strips those, the run ended with an empty output, and the job turned the
# blank message into a handoff the customer never asked for. See
# docs/adaki/captain-remediacion.md §7.2.
#
# For a support bot that looks up FAQs and routes to scenarios, unbounded
# reasoning buys nothing and costs latency and money, so 'off' is the
# default. The params are deep-merged into the request payload by RubyLLM
# (Provider#complete → Utils.deep_merge), so they must mirror the provider's
# own payload shape.
module Llm::Thinking
  OFF = 'off'.freeze
  LOW = 'low'.freeze
  DYNAMIC = 'dynamic'.freeze
  LEVELS = [OFF, LOW, DYNAMIC].freeze
  DEFAULT_LEVEL = OFF

  # Gemini 2.5 Pro cannot disable thinking: its budget floor is 128 tokens,
  # and sending 0 is rejected by the API. 2.5 Flash/Flash-Lite accept 0, and
  # their lowest non-zero budget is 512.
  PRO_MINIMUM_BUDGET = 128
  FLASH_LOW_BUDGET = 512

  module_function

  def normalize_level(level)
    level = level.to_s
    LEVELS.include?(level) ? level : DEFAULT_LEVEL
  end

  # @return [Hash] provider params to merge into the chat payload; empty when
  #   the level is 'dynamic' (send nothing, let the provider decide) or the
  #   provider has no supported knob.
  def params_for(provider:, model:, level:)
    level = normalize_level(level)
    return {} if level == DYNAMIC
    return {} unless %w[gemini google].include?(provider.to_s)

    { generationConfig: { thinkingConfig: gemini_thinking_config(model.to_s, level) } }
  end

  # Gemini 3 replaced the numeric budget with thinkingLevel. Flash supports a
  # minimal level; Pro does not, so its minimum is low.
  def gemini_thinking_config(model, level)
    return gemini_3_thinking_config(model, level) if model.start_with?('gemini-3')

    { thinkingBudget: gemini_budget(model, level) }
  end

  def gemini_budget(model, level)
    return PRO_MINIMUM_BUDGET if model.include?('pro')
    return 0 if level == OFF

    FLASH_LOW_BUDGET
  end

  def gemini_3_thinking_config(model, level)
    # Gemini 3 Pro has no "minimal" level; low is its minimum. Flash models
    # support minimal, which is the closest provider-supported equivalent to
    # Captain's default "off" setting.
    minimum = model.include?('pro') ? 'low' : 'minimal'
    { thinkingLevel: level == OFF ? minimum : 'low' }
  end
end
