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

    def with_api_key(api_key, api_base: nil)
      initialize!
      effective_base = api_base.to_s.presence
      context = RubyLLM.context do |config|
        config.openai_api_key = api_key
        config.openai_api_base = effective_base if effective_base
      end

      yield context
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
