# Turns an assistant's "reasoning level" setting into the provider-specific
# request parameters that cap (or disable) the model's internal reasoning.
#
# Why this exists: reasoning-capable providers use different payloads. Gemini
# expects `thinkingConfig`, OpenAI expects `reasoning_effort`, and DeepSeek
# expects its `thinking` toggle plus effort. Leaving each provider's default
# unrestricted made thought-only Gemini replies possible (RubyLLM strips those
# parts and Captain then saw an empty output) and made the Captain selector's
# reasoning setting ineffective for OpenAI/DeepSeek.
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

  # Thread-local kill switch, see .without_params.
  SUPPRESS_KEY = :llm_thinking_params_suppressed

  module_function

  def normalize_level(level)
    level = level.to_s
    LEVELS.include?(level) ? level : DEFAULT_LEVEL
  end

  # Runs the block with every provider reasoning param disabled on this
  # thread. Captain uses it to replay a turn after the provider rejected the
  # params we guessed for a model this table does not know yet (2026-09-04,
  # account 4: gpt-5.4-mini answered 400 "'reasoning_effort' does not support
  # 'minimal'" and the customer got a handoff instead of an answer). Provider
  # catalogues move faster than this mapping; a rejected knob must cost one
  # retry, never the conversation.
  def without_params
    previous = Thread.current[SUPPRESS_KEY]
    Thread.current[SUPPRESS_KEY] = true
    yield
  ensure
    Thread.current[SUPPRESS_KEY] = previous
  end

  def suppressed?
    Thread.current[SUPPRESS_KEY] == true
  end

  # @return [Hash] provider params to merge into the chat payload; empty when
  #   the level is 'dynamic' (send nothing, let the provider decide), the
  #   provider has no supported knob, or .without_params is active.
  def params_for(provider:, model:, level:)
    return {} if suppressed?

    level = normalize_level(level)
    return {} if level == DYNAMIC

    provider = provider.to_s
    model = model.to_s

    case provider
    when 'gemini', 'google'
      { generationConfig: { thinkingConfig: gemini_thinking_config(model, level) } }
    when 'openai'
      openai_reasoning_params(model, level)
    when 'deepseek'
      deepseek_reasoning_params(model, level)
    else
      {}
    end
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
    # Gemini 3 Pro and newer Flash variants have a low minimum. Gemini 3
    # Flash preview accepts minimal, which is the closest provider-supported
    # equivalent to Captain's default "off" setting.
    minimum = model.include?('pro') || model.include?('3.7') ? 'low' : 'minimal'
    { thinkingLevel: level == OFF ? minimum : 'low' }
  end

  def openai_reasoning_params(model, level)
    return {} unless model.match?(/\A(?:gpt-5|o[134])/)

    { reasoning_effort: level == OFF ? openai_off_effort(model) : 'low' }
  end

  # The gpt-5.0 family (gpt-5, gpt-5-mini, gpt-5-nano, gpt-5-chat…) accepts
  # 'minimal' and rejects 'none'; gpt-5.1 and every later release (5.2, 5.4,
  # …) accept 'none' and dropped 'minimal'. o-series models bottom out at
  # 'low'. Matching "5.0 vs anything newer" instead of listing versions keeps
  # the next release from turning into a 400 (see .without_params for the
  # safety net when a model still surprises us).
  def openai_off_effort(model)
    return 'low' if model.start_with?('o')

    model.match?(/\Agpt-5(?:-|\z)/) ? 'minimal' : 'none'
  end

  def deepseek_reasoning_params(model, level)
    # DeepSeek's current V4 API exposes the thinking toggle and effort on both
    # V4 Flash and V4 Pro. Keep the legacy alias for older installations that
    # have not migrated their stored preference yet.
    return {} unless model.start_with?('deepseek-v4-') || model.include?('reasoner')

    return { thinking: { type: 'disabled' } } if level == OFF

    { thinking: { type: 'enabled' }, reasoning_effort: 'low' }
  end
end
