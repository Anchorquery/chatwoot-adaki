# frozen_string_literal: true

# Base service for LLM operations using RubyLLM.
# New features should inherit from this class.
class Llm::BaseAiService
  DEFAULT_MODEL = Llm::Config::DEFAULT_MODEL
  DEFAULT_TEMPERATURE = 1.0

  attr_reader :model, :temperature

  def initialize
    Llm::Config.initialize!
    setup_model
    setup_temperature
  end

  def chat(model: @model, temperature: @temperature)
    RubyLLM.chat(model: model).with_temperature(temperature)
  end

  private

  # Strips markdown code fences (```json ... ``` or ``` ... ```) that some
  # LLM providers/gateways wrap around JSON responses despite response_format hints.
  def sanitize_json_response(response)
    return response if response.nil?

    response.strip.sub(/\A```(?:\w*)\s*\n?/, '').sub(/\n?\s*```\s*\z/, '').strip
  end

  # Override in subclasses to specify the feature key (e.g. 'assistant', 'copilot',
  # 'editor', 'label_suggestion'). Returning nil falls back to InstallationConfig
  # for backward compatibility with installs that have not migrated to
  # platform_credential_models yet.
  def feature_key
    nil
  end

  # Override in subclasses to scope model resolution by account.
  def resolver_account
    nil
  end

  def setup_model
    resolved = Platform::Models::Resolver.resolve(
      account: resolver_account,
      feature: feature_key,
      fallback_model: DEFAULT_MODEL
    )

    if resolved.present?
      @model = resolved[:model_slug]
      @resolved_credential = resolved[:credential]
      return
    end

    config_value = InstallationConfig.find_by(name: 'CAPTAIN_OPEN_AI_MODEL')&.value
    @model = (config_value.presence || DEFAULT_MODEL)
  end

  def setup_temperature
    @temperature = DEFAULT_TEMPERATURE
  end
end
