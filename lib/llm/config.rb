require 'ruby_llm'
require 'agents'
require 'digest'

module Llm::Config
  DEFAULT_MODEL = 'gpt-4.1-mini'.freeze

  # Providers fully wired for per-credential routing. Add a provider here
  # once its RubyLLM setters are mapped in #apply_provider_credential.
  #
  # Must live at module level (NOT inside `class << self` below): a constant
  # defined inside `class << self` belongs to the singleton class and is
  # invisible as `Llm::Config::SUPPORTED_RUNTIME_PROVIDERS`. That exact
  # lookup from Platform::Models::Resolver raised NameError on every Captain
  # V2 run whose resolution reached the fallback path (2026-09-04, account 3:
  # every customer message became an instant handoff without an LLM call).
  SUPPORTED_RUNTIME_PROVIDERS = %w[openai gemini deepseek].freeze

  # InstallationConfig name -> RubyLLM config setter mapping for every
  # provider. Add a row here + a matching entry in installation_config.yml
  # to expose a new provider in the Super Admin UI.
  PROVIDER_KEYS = {
    'CAPTAIN_OPEN_AI_API_KEY' => :openai_api_key,
    'CAPTAIN_OPEN_AI_ENDPOINT' => :openai_api_base,
    'CAPTAIN_ANTHROPIC_API_KEY' => :anthropic_api_key,
    'CAPTAIN_GEMINI_API_KEY' => :gemini_api_key,
    'CAPTAIN_DEEPSEEK_API_KEY' => :deepseek_api_key,
    'CAPTAIN_OPENROUTER_API_KEY' => :openrouter_api_key,
    'CAPTAIN_OLLAMA_API_BASE' => :ollama_api_base,
    'CAPTAIN_BEDROCK_API_KEY' => :bedrock_api_key,
    'CAPTAIN_BEDROCK_SECRET_KEY' => :bedrock_secret_key,
    'CAPTAIN_BEDROCK_REGION' => :bedrock_region
  }.freeze

  class << self
    def initialized?
      !@configured_fingerprint.nil?
    end

    # Re-reads InstallationConfig every call (cheap: 10 indexed lookups) and
    # only re-runs RubyLLM.configure/Agents.configure (which mutate global gem
    # state) when the resolved values actually changed since last time. This
    # is what lets a Super Admin rotate a key and have it take effect on the
    # next call, without a container restart — previously only a full app
    # reboot picked up a changed InstallationConfig row. See
    # docs/adaki/captain-remediacion.md §2c.
    #
    # Deliberately NOT time-cached: caching provider_values itself (e.g. a
    # 30s TTL) would let a value from one RSpec example leak into another,
    # since transactional-fixture rollback resets the DB but not a Ruby-level
    # ivar. Only the cheap-to-compare fingerprint is memoized.
    def initialize!
      values = provider_values
      fingerprint = fingerprint_for(values)
      return if @configured_fingerprint == fingerprint

      configure_ruby_llm(values)
      configure_agents_sdk(values)
      @configured_fingerprint = fingerprint
    end

    def reset!
      @configured_fingerprint = nil
    end

    # Whether an account with no Platform::Credential of its own may
    # silently fall back to the shared global RubyLLM config (built from
    # InstallationConfig's own API keys). Defaults to true (today's
    # existing behavior, unchanged) so shipping this doesn't flip anyone's
    # Captain off — an operator running multiple accounts on one install
    # opts into strict mode explicitly by setting this InstallationConfig
    # row to false once every account that needs Captain has its own
    # credential. See docs/adaki/captain-remediacion.md §Fase 2c.
    def global_fallback_allowed?
      value = InstallationConfig.find_by(name: 'CAPTAIN_ALLOW_GLOBAL_FALLBACK')&.value
      return true if value.nil?

      ActiveModel::Type::Boolean.new.cast(value)
    end

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
    # RubyLLM setters. OpenAI, Gemini and DeepSeek use their native clients;
    # legacy providers retain the existing OpenAI-compatible fallback until
    # their own runtime adapters are explicitly enabled.
    def apply_provider_credential(config, provider, api_key, effective_base)
      case provider
      when 'gemini', 'google'
        config.gemini_api_key = api_key
        config.gemini_api_base = effective_base if effective_base
      when 'openai'
        config.openai_api_key = api_key
        config.openai_api_base = effective_base if effective_base
      when 'deepseek'
        config.deepseek_api_key = api_key
        config.deepseek_api_base = effective_base if effective_base
      else
        Rails.logger.warn(
          "[Llm::Config] Provider '#{provider}' is not fully supported yet. " \
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

    # Strips whitespace: a key pasted with a trailing newline/space into the
    # Super Admin form previously reached RubyLLM verbatim and failed auth
    # with no obvious reason in the provider's error message.
    def provider_values
      PROVIDER_KEYS.each_with_object({}) do |(config_name, setter), h|
        value = InstallationConfig.find_by(name: config_name)&.value.to_s.strip.presence
        value = value.chomp('/') if setter == :openai_api_base && value.present?
        h[setter] = value
      end
    end

    def fingerprint_for(values)
      Digest::SHA256.hexdigest(values.sort.to_s)
    end

    def configure_ruby_llm(values)
      RubyLLM.configure do |config|
        values.each do |setter, value|
          next unless value.present?

          # Some RubyLLM versions may not expose every setter; skip silently.
          config.public_send("#{setter}=", value) if config.respond_to?("#{setter}=")
        end
        config.model_registry_file = Rails.root.join('config/llm_models.json').to_s
        config.logger = Rails.logger
        # Defaults are request_timeout 300s / max_retries 3 / retry_interval
        # 0.1s — a provider hiccup could keep a Sidekiq worker busy for
        # minutes retrying inside Faraday alone. Job-level retry_on already
        # handles backoff for transient failures (see Captain::FailurePolicy
        # + response_builder_job.rb), so this only needs to fail fast enough
        # for that outer layer to take over. See
        # docs/adaki/captain-remediacion.md §3.
        config.request_timeout = 60
        config.max_retries = 1
        config.retry_interval = 1
      end
    end

    # Mirrors what config/initializers/ai_agents.rb used to do once at boot.
    # Called on every #initialize! (fingerprint-gated like RubyLLM above) so
    # the ai-agents gem picks up a rotated OpenAI key/model/endpoint too,
    # without needing its own separate reload path.
    def configure_agents_sdk(values)
      api_key = values[:openai_api_key]
      return if api_key.blank?

      Agents.configure do |config|
        config.openai_api_key = api_key
        endpoint = agents_openai_endpoint
        config.openai_api_base = "#{endpoint.chomp('/')}/v1" if endpoint.present?
        config.default_model = agents_openai_model
        config.debug = false
      end
    end

    def agents_openai_model
      InstallationConfig.find_by(name: 'CAPTAIN_OPEN_AI_MODEL')&.value.presence || LlmConstants::DEFAULT_MODEL
    end

    def agents_openai_endpoint
      InstallationConfig.find_by(name: 'CAPTAIN_OPEN_AI_ENDPOINT')&.value || LlmConstants::OPENAI_API_ENDPOINT
    end
  end
end
