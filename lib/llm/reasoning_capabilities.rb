# Which reasoning "efforts" a given model accepts, and which one Captain's
# abstract level (off / low / dynamic) should map to.
#
# Modelled on how the industry does it (OpenRouter's per-model
# `reasoning.supported_efforts`, Vercel AI Gateway's per-family table,
# LiteLLM's model map + drop_params): the truth about a model lives in data,
# per model, and the code only holds a first guess by family. Three layers:
#
#   1. seed_for        — the family table (first guess when a row knows nothing)
#   2. reasoning_config — the platform_credential_models row: seeded on import,
#                         corrected from the provider's own 400 (OpenAI lists
#                         "Supported values are: …"), editable in the providers
#                         view. When present it always wins over the seed.
#   3. Llm::Thinking.without_params — last-resort replay with no params at all.
#
# Vocabulary is OpenAI/OpenRouter's, lowest to highest. Llm::Thinking renders
# an effort into each provider's payload (Gemini budgets/levels, DeepSeek
# thinking toggle, OpenAI reasoning_effort).
module Llm::ReasoningCapabilities
  EFFORTS = %w[none minimal low medium high xhigh].freeze
  # "off" means: the lowest the model can go. "low" means: low, or the
  # closest thing the model offers.
  OFF_PREFERENCE = %w[none minimal low].freeze
  LOW_PREFERENCE = %w[low minimal none medium].freeze
  SOURCES = %w[seed provider manual].freeze

  # OpenAI: "Unsupported value: 'reasoning_effort' does not support 'minimal'
  # with this model. Supported values are: 'none', 'low', 'medium', 'high',
  # and 'xhigh'."
  SUPPORTED_VALUES_PATTERN = /supported values(?:\s+are)?\s*:?\s*([^.\n]+)/i

  module_function

  # First guess by family. Sources: OpenAI model pages / Vercel AI Gateway
  # reasoning table (GPT-5.0 family accepts minimal, 5.1+ accepts none, xhigh
  # from 5.2, codex has no none, pro has no low, o-series bottoms out at low),
  # Google thinking docs (2.5 Flash accepts budget 0, 2.5 Pro floors at 128,
  # Gemini 3 uses levels, Flash has minimal, Pro does not), DeepSeek V4 API
  # (thinking toggle + effort). Unknown model → [] → nothing is sent.
  def seed_for(provider:, model:)
    model = model.to_s
    case normalize_provider(provider)
    when 'openai' then openai_seed(model)
    when 'gemini' then gemini_seed(model)
    when 'deepseek' then deepseek_seed(model)
    else []
    end
  end

  def openai_seed(model)
    return %w[low medium high] if model.match?(/\Ao[134]/)
    return [] unless model.match?(/\Agpt-(?:5|[6-9]|\d{2})/)
    return %w[medium high xhigh] if model.include?('-pro')
    return %w[low medium high xhigh] if model.include?('codex')
    return %w[minimal low medium high] if model.match?(/\Agpt-5(?:-|\z)/)
    return %w[none low medium high] if model.start_with?('gpt-5.1')

    %w[none low medium high xhigh]
  end

  def gemini_seed(model)
    return [] unless model.start_with?('gemini-2.5', 'gemini-3')

    pro = model.include?('pro')
    if model.start_with?('gemini-3')
      pro ? %w[low medium high] : %w[minimal low medium high]
    else
      pro ? %w[low medium high] : %w[none low medium high]
    end
  end

  def deepseek_seed(model)
    reasoning = model.start_with?('deepseek-v4') || model.include?('reasoner') || model == 'deepseek-chat'
    reasoning ? %w[none low medium high] : []
  end

  def seed_config(provider:, model:)
    { 'supported_efforts' => seed_for(provider: provider, model: model), 'source' => 'seed' }
  end

  # Efforts stored on a row's reasoning_config, or nil when the row says
  # nothing yet. An explicit [] is meaningful: the model rejects the knob.
  def stored_efforts(config)
    return nil unless config.is_a?(Hash)

    efforts = config['supported_efforts'] || config[:supported_efforts]
    return nil unless efforts.is_a?(Array)

    efforts.map(&:to_s) & EFFORTS
  end

  # Row wins, seed otherwise.
  def efforts_for(provider:, model:, config: nil)
    stored_efforts(config) || seed_for(provider: provider, model: model)
  end

  # @return [String, nil] the effort to send for Captain's level, nil for
  #   "send nothing" (dynamic, or the model offers nothing suitable).
  def effort_for_level(efforts, level)
    efforts = Array(efforts)
    case level.to_s
    when 'off' then OFF_PREFERENCE.find { |effort| efforts.include?(effort) }
    when 'low' then LOW_PREFERENCE.find { |effort| efforts.include?(effort) }
    end
  end

  # Efforts the provider itself listed in a rejection, nil when the message
  # names none (Gemini/DeepSeek phrase theirs as "not supported").
  def parse_supported_values(message)
    match = message.to_s.match(SUPPORTED_VALUES_PATTERN)
    return nil unless match

    (match[1].scan(/[a-z]+/i).map(&:downcase) & EFFORTS).presence
  end

  # Records what the provider just told us on the model's row so the next
  # turn gets it right first time. No list in the message → the model takes
  # no reasoning params at all ([]). Returns the learned efforts, nil when
  # there was no row to learn on.
  def learn_from_rejection!(model_row, message)
    return nil if model_row.blank?

    efforts = parse_supported_values(message) || []
    model_row.update!(
      reasoning_config: (model_row.reasoning_config || {}).merge(
        'supported_efforts' => efforts,
        'source' => 'provider',
        'learned_at' => Time.current.iso8601,
        'last_error' => message.to_s.truncate(300)
      )
    )
    Rails.logger.info(
      "[Llm::ReasoningCapabilities] learned supported_efforts=#{efforts.inspect} for model=#{model_row.slug} " \
      "credential=#{model_row.credential_id}"
    )
    efforts
  rescue StandardError => e
    Rails.logger.error("[Llm::ReasoningCapabilities] could not persist learned efforts: #{e.message}")
    nil
  end

  def normalize_provider(provider)
    provider = provider.to_s
    provider == 'google' ? 'gemini' : provider
  end
end
