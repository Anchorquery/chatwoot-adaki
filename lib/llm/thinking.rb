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
#
# Which efforts a model accepts is NOT decided here: Llm::ReasoningCapabilities
# answers that from the model's own row (seeded by family, corrected from the
# provider's rejections, editable in the providers view). This module only
# picks the effort for Captain's level and renders it for the provider.
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
  # params we guessed for a model nothing knew about yet (2026-09-04,
  # account 4: gpt-5.4-mini answered 400 "'reasoning_effort' does not support
  # 'minimal'" and the customer got a handoff instead of an answer). Provider
  # catalogues move faster than any mapping; a rejected knob must cost one
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

  # @param supported_efforts [Array<String>, nil] efforts the model accepts
  #   (from its platform_credential_models row); nil → family seed.
  # @return [Hash] provider params to merge into the chat payload; empty when
  #   the level is 'dynamic' (send nothing, let the provider decide), the
  #   model offers no suitable effort, or .without_params is active.
  def params_for(provider:, model:, level:, supported_efforts: nil)
    return {} if suppressed?

    level = normalize_level(level)
    return {} if level == DYNAMIC

    provider = Llm::ReasoningCapabilities.normalize_provider(provider)
    model = model.to_s
    efforts = supported_efforts.nil? ? Llm::ReasoningCapabilities.seed_for(provider: provider, model: model) : Array(supported_efforts)
    effort = Llm::ReasoningCapabilities.effort_for_level(efforts, level)
    return {} if effort.nil?

    render(provider, model, effort)
  end

  def render(provider, model, effort)
    case provider
    when 'gemini' then { generationConfig: { thinkingConfig: gemini_thinking_config(model, effort) } }
    when 'openai' then { reasoning_effort: effort }
    when 'deepseek' then deepseek_params(effort)
    else {}
    end
  end

  # Gemini 3 replaced the numeric budget with thinkingLevel; 2.5 takes a
  # token budget (0 disables it on Flash, Pro floors at 128).
  def gemini_thinking_config(model, effort)
    return { thinkingLevel: effort } if model.start_with?('gemini-3')

    { thinkingBudget: gemini_budget(model, effort) }
  end

  def gemini_budget(model, effort)
    return PRO_MINIMUM_BUDGET if model.include?('pro')

    effort == 'none' ? 0 : FLASH_LOW_BUDGET
  end

  def deepseek_params(effort)
    return { thinking: { type: 'disabled' } } if effort == 'none'

    { thinking: { type: 'enabled' }, reasoning_effort: effort }
  end
end
