class Platform::CredentialManager
  LegacyCredential = Struct.new(:account, :provider, :purpose, :key, :name, :auth_type, :payload, :metadata) do
    def secret(name)
      payload[name.to_s] || payload[name.to_sym]
    end

    def token_hint
      metadata['token_hint'] || metadata[:token_hint]
    end
  end

  PROVIDER_DEFAULT_KEYS = {
    'openai' => 'openai.default',
    'anthropic' => 'anthropic.default',
    'gemini' => 'gemini.default',
    'deepseek' => 'deepseek.default',
    'openrouter' => 'openrouter.default',
    'ollama' => 'ollama.default',
    'bedrock' => 'bedrock.default',
    'firecrawl' => 'firecrawl.default'
  }.freeze

  class << self
    def store!(account:, provider:, purpose:, key:, name:, auth_type:, payload:, metadata: {}, owner: nil, user: nil)
      credential = Platform::Credential.find_or_initialize_by(account: account, key: key)
      credential.provider = provider
      credential.purpose = purpose
      credential.name = name
      credential.auth_type = auth_type
      credential.owner = owner
      credential.created_by = user if credential.new_record?
      credential.updated_by = user
      credential.payload = payload
      credential.metadata = metadata
      credential.status = :active
      credential.save!
      credential
    end

    def fetch!(account:, key:, provider: nil, purpose: nil)
      credential = fetch_optional(account: account, key: key, provider: provider, purpose: purpose)
      return credential if credential.present?

      raise CustomExceptions::Platform::MissingCredential.new(account: account, key: key, provider: provider, purpose: purpose)
    end

    def fetch_optional(account:, key:, provider: nil, purpose: nil)
      credential = if credentials_table_available?
                     account_credential(account: account, key: key, provider: provider, purpose: purpose) ||
                       global_credential(key: key, provider: provider, purpose: purpose)
                   end

      credential || legacy_credential(key: key)
    end

    def rotate!(credential:, payload:, user: nil)
      credential.payload = payload
      credential.updated_by = user
      credential.status = :active
      credential.last_validated_at = Time.current
      credential.save!
      credential
    end

    def revoke!(credential:, user: nil)
      credential.updated_by = user
      credential.status = :revoked
      credential.save!
      credential
    end

    def validate!(credential:)
      validator_for(credential).validate!
    end

    def record_use!(credential:, used_by:, operation:, status:, error_code: nil, context: {})
      Platform::CredentialUsage.create!(
        account: credential.account,
        platform_credential: credential,
        used_by: used_by,
        operation: operation,
        status: status,
        error_code: error_code,
        context: context
      )
      credential.update_column(:last_used_at, Time.current)
    end

    def default_key_for(provider)
      PROVIDER_DEFAULT_KEYS[provider.to_s] || "#{provider}.default"
    end

    def with_credential_context(account:, key:, provider: nil, purpose: nil, api_base: nil)
      credential = fetch!(account: account, key: key, provider: provider, purpose: purpose)
      payload = credential.payload
      access_token = payload[:api_key] || payload['api_key'] || payload[:token] || payload['token'] || payload[:access_token] || payload['access_token']
      metadata = credential.metadata.is_a?(Hash) ? credential.metadata : {}
      api_base ||= metadata['api_base'].to_s.presence || metadata[:api_base].to_s.presence

      raise CustomExceptions::Platform::MissingCredential.new(account: account, key: key, provider: provider, purpose: purpose) if access_token.blank?

      Llm::Config.with_api_key(access_token, api_base: api_base) do |context|
        yield context, credential
      end
    end

    private

    def account_credential(account:, key:, provider: nil, purpose: nil)
      scope = Platform::Credential.where(account: account, key: key)
      scope = scope.where(provider: provider) if provider.present?
      scope = scope.where(purpose: purpose) if purpose.present?
      scope.active.first
    end

    def global_credential(key:, provider: nil, purpose: nil)
      scope = Platform::Credential.where(account_id: nil, key: key)
      scope = scope.where(provider: provider) if provider.present?
      scope = scope.where(purpose: purpose) if purpose.present?
      scope.active.first
    end

    def legacy_credential(key:)
      legacy = Platform::Credentials::LegacyInstallationConfigAdapter.fetch(key)
      return nil if legacy.blank?

      LegacyCredential.new(
        nil,
        legacy[:provider],
        legacy[:purpose],
        legacy[:key],
        legacy[:name],
        legacy[:auth_type],
        legacy[:payload].with_indifferent_access,
        legacy[:metadata].with_indifferent_access
      )
    end

    def validator_for(credential)
      case credential.provider
      when 'openai' then Platform::Credentials::Validators::OpenaiValidator.new(credential)
      when 'anthropic' then Platform::Credentials::Validators::AnthropicValidator.new(credential)
      when 'gemini' then Platform::Credentials::Validators::GeminiValidator.new(credential)
      when 'firecrawl' then Platform::Credentials::Validators::FirecrawlValidator.new(credential)
      when 'ollama' then Platform::Credentials::Validators::OllamaValidator.new(credential)
      when 'bedrock' then Platform::Credentials::Validators::BedrockValidator.new(credential)
      else Platform::Credentials::Validators::GenericHttpValidator.new(credential)
      end
    end

    def credentials_table_available?
      ActiveRecord::Base.connection.data_source_exists?(Platform::Credential.table_name)
    rescue ActiveRecord::StatementInvalid, ActiveRecord::NoDatabaseError
      false
    end
  end
end
