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

  # When a per-credential context is active (set via #with_llm_credential in
  # subclasses), build the chat from it so the right provider key/base is used.
  # Falls back to the global RubyLLM config otherwise.
  def chat(model: @model, temperature: @temperature)
    client = @llm_context || RubyLLM
    client.chat(model: model).with_temperature(temperature)
  end

  private

  # Strips markdown code fences (```json ... ``` or ``` ... ```) that some
  # LLM providers/gateways wrap around JSON responses despite response_format hints.
  def sanitize_json_response(response)
    return response if response.nil?

    response.strip.sub(/\A```(?:\w*)\s*\n?/, '').sub(/\n?\s*```\s*\z/, '').strip
  end

  # Provider-aware JSON mode params. OpenAI uses a top-level `response_format`;
  # Gemini expects `generationConfig.responseMimeType`. Sending OpenAI's shape
  # to Gemini makes the Google API reject the request. `extra` lets callers add
  # provider-agnostic params (e.g. max_tokens) that are merged in.
  def json_mode_params(extra = {})
    base = case llm_request_provider
           when 'gemini' then { generationConfig: { responseMimeType: 'application/json' } }
           when 'openai' then { response_format: { type: 'json_object' } }
           else {}
           end
    base.merge(extra)
  end

  # Resolves the provider for the model/credential currently in use.
  # Prefers the credential resolved in #setup_model, then the model registry,
  # then falls back to OpenAI.
  def llm_request_provider
    provider = nil
    provider ||= @resolved_credential.provider if @resolved_credential.respond_to?(:provider)
    provider ||= Llm::Models.models[@model]&.fetch('provider', nil) if @model && defined?(Llm::Models)
    provider.to_s.presence || 'openai'
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
