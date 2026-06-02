require 'ruby_llm'

module Llm::Config
  DEFAULT_MODEL = 'gpt-4.1-mini'.freeze

  # InstallationConfig name -> RubyLLM config setter mapping for every
  # provider. Add a row here + a matching entry in installation_config.yml
  # to expose a new provider in the Super Admin UI.
  PROVIDER_KEYS = {
    'CAPTAIN_OPEN_AI_API_KEY'      => :openai_api_key,
    'CAPTAIN_OPEN_AI_ENDPOINT'     => :openai_api_base,
    'CAPTAIN_ANTHROPIC_API_KEY'    => :anthropic_api_key,
    'CAPTAIN_GEMINI_API_KEY'       => :gemini_api_key,
    'CAPTAIN_DEEPSEEK_API_KEY'     => :deepseek_api_key,
    'CAPTAIN_OPENROUTER_API_KEY'   => :openrouter_api_key,
    'CAPTAIN_OLLAMA_API_BASE'      => :ollama_api_base,
    'CAPTAIN_BEDROCK_API_KEY'      => :bedrock_api_key,
    'CAPTAIN_BEDROCK_SECRET_KEY'   => :bedrock_secret_key,
    'CAPTAIN_BEDROCK_REGION'       => :bedrock_region
  }.freeze

  class << self
    def initialized?
      @initialized ||= false
    end

    def initialize!
      return if @initialized

      configure_ruby_llm
      @initialized = true
    end

    def reset!
      @initialized = false
    end

    # Providers fully wired for per-credential routing. Add a provider here
    # once its RubyLLM setters are mapped in #apply_provider_credential.
    SUPPORTED_RUNTIME_PROVIDERS = %w[openai gemini].freeze

    def with_api_key(api_key, api_base: nil, provider: 'openai')
      yield context_for(api_key, api_base: api_base, provider: provider)
    end

    # Builds (and returns) a reusable RubyLLM context scoped to a single
    # credential. Unlike #with_api_key it does not require a block, so callers
    # that need to keep the context around (e.g. to inject it into a chat via
    # RubyLLM::Chat#with_context) can store it. The context dups the global
    # config and overrides only the resolved provider's key/base.
    def context_for(api_key, api_base: nil, provider: 'openai')
      initialize!
      effective_base = api_base.to_s.presence
      normalized_provider = provider.to_s.presence || 'openai'

      RubyLLM.context do |config|
        apply_provider_credential(config, normalized_provider, api_key, effective_base)
      end
    end

    # Builds a RubyLLM context from a Platform::Credential (or any object that
    # responds to #secret/#payload + #provider + #metadata). Returns nil when
    # the credential is blank or carries no usable api_key, so callers can fall
    # back to the global RubyLLM config (legacy installs using InstallationConfig).
    def context_for_credential(credential)
      return nil if credential.blank?

      api_key = credential_api_key(credential)
      return nil if api_key.blank?

      metadata = credential.respond_to?(:metadata) && credential.metadata.is_a?(Hash) ? credential.metadata : {}
      api_base = metadata['api_base'].to_s.presence || metadata[:api_base].to_s.presence
      provider = (credential.respond_to?(:provider) ? credential.provider : nil).to_s.presence || 'openai'

      context_for(api_key, api_base: api_base, provider: provider)
    end

    def credential_api_key(credential)
      return credential.secret(:api_key) if credential.respond_to?(:secret)

      payload = credential.respond_to?(:payload) ? credential.payload : nil
      payload && (payload[:api_key] || payload['api_key'])
    end

    # Maps a credential (provider + key + optional base) onto the right
    # RubyLLM setters. OpenAI and Google Gemini are supported; any other
    # provider logs a warning and falls back to the OpenAI-compatible path
    # so the call still has a chance to work via a custom api_base.
    def apply_provider_credential(config, provider, api_key, effective_base)
      case provider
      when 'gemini', 'google'
        config.gemini_api_key = api_key
        config.gemini_api_base = effective_base if effective_base
      when 'openai'
        config.openai_api_key = api_key
        config.openai_api_base = effective_base if effective_base
      else
        Rails.logger.warn(
          "[Llm::Config] Provider '#{provider}' is not fully supported yet. " \
          'Only openai and gemini are wired for per-credential routing. ' \
          'Falling back to the OpenAI-compatible client; configure a custom ' \
          'api_base if this provider speaks the OpenAI protocol.'
        )
        config.openai_api_key = api_key
        config.openai_api_base = effective_base if effective_base
      end
    end

    # Returns the list of providers with credentials present. Useful for
    # the Super Admin diagnostic page and for unit tests.
    def enabled_providers
      provider_values.filter_map do |setter, value|
        next unless value.present?

        case setter
        when :openai_api_key      then :openai
        when :anthropic_api_key   then :anthropic
        when :gemini_api_key      then :gemini
        when :deepseek_api_key    then :deepseek
        when :openrouter_api_key  then :openrouter
        when :ollama_api_base     then :ollama
        when :bedrock_api_key     then :bedrock
        end
      end.uniq
    end

    private

    def provider_values
      @provider_values = PROVIDER_KEYS.each_with_object({}) do |(config_name, setter), h|
        value = InstallationConfig.find_by(name: config_name)&.value
        value = value.to_s.chomp('/') if setter == :openai_api_base && value.present?
        h[setter] = value
      end
    end

    def configure_ruby_llm
      RubyLLM.configure do |config|
        provider_values.each do |setter, value|
          next unless value.present?
          # Some RubyLLM versions may not expose every setter; skip silently.
          config.public_send("#{setter}=", value) if config.respond_to?("#{setter}=")
        end
        config.model_registry_file = Rails.root.join('config/llm_models.json').to_s
        config.logger = Rails.logger
      end
    end
  end
end
