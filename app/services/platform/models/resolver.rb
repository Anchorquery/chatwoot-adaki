# Resolves the (credential, model_slug) pair to use at runtime for a given
# account/feature. Consults the new platform_credential_models table so the
# UI toggle is honored, with safe fallbacks for installs that have not
# enabled any model yet.
class Platform::Models::Resolver
  def self.resolve(account:, feature: nil, kind: nil, preferred_slug: nil, fallback_model: nil)
    new(
      account: account,
      feature: feature,
      kind: kind,
      preferred_slug: preferred_slug,
      fallback_model: fallback_model
    ).resolve
  end

  def initialize(account:, feature: nil, kind: nil, preferred_slug: nil, fallback_model: nil)
    @account = account
    @feature = feature.to_s.presence
    @kind = kind.to_s.presence
    @preferred_slug = Llm::Models.canonical_model_slug(preferred_slug).presence
    @fallback_model = fallback_model.to_s.presence || Llm::Config::DEFAULT_MODEL
  end

  # Returns a Hash { credential:, model_slug:, source: } or nil.
  def resolve
    return nil if @account.nil?

    pair = resolve_by_preferred_slug ||
           resolve_by_feature ||
           resolve_by_kind ||
           resolve_any_enabled ||
           resolve_fallback

    return nil unless pair

    {
      credential: pair[:credential],
      model_slug: pair[:model_slug],
      source: pair[:source]
    }
  end

  private

  def resolve_by_preferred_slug
    return nil if @preferred_slug.blank?

    model = enabled_scope.where(slug: @preferred_slug).first
    return { credential: model.credential, model_slug: canonical_slug(model.slug), source: :preferred } if model

    provider = Llm::Models.models.dig(@preferred_slug, 'provider')
    return nil if provider.blank?

    credential = supported_active_credentials.find do |candidate|
      normalized_provider(candidate.provider) == normalized_provider(provider)
    end
    return nil unless credential

    { credential: credential, model_slug: @preferred_slug, source: :preferred_catalog }
  end

  def resolve_by_feature
    return nil if @feature.blank?

    feature_models = Llm::Models.models_for(@feature)
    return nil if feature_models.blank?

    model = enabled_scope.where(slug: feature_models).first
    return nil unless model

    { credential: model.credential, model_slug: canonical_slug(model.slug), source: :feature }
  end

  def resolve_by_kind
    return nil if @kind.blank?

    model = enabled_scope.where(kind: @kind).first
    return nil unless model

    { credential: model.credential, model_slug: canonical_slug(model.slug), source: :kind }
  end

  def resolve_any_enabled
    model = enabled_scope.first
    return nil unless model

    { credential: model.credential, model_slug: canonical_slug(model.slug), source: :any_enabled }
  end

  def resolve_fallback
    # Prefer a native runtime provider, but preserve the legacy fallback for
    # accounts that only have an older OpenAI-compatible credential.
    credential = supported_active_credentials.first || active_credentials.first
    return nil unless credential

    { credential: credential, model_slug: fallback_slug_for(credential), source: :fallback }
  end

  # RubyLLM routes by the model slug, so the fallback slug MUST belong to the
  # chosen credential's provider — otherwise a Gemini key would be sent to
  # OpenAI (the slug is gpt-*) and rejected. Precedence:
  #   1. a model already synced onto this credential (prefer chat kind),
  #   2. the feature's default/first model that matches the provider,
  #   3. a provider-appropriate default (the OpenAI-shaped @fallback_model is
  #      only safe to use when the provider is actually openai).
  def fallback_slug_for(credential)
    provider = normalized_provider(credential.provider)

    synced = credential.models.where(kind: 'chat').order(:id).first || credential.models.order(:id).first
    return canonical_slug(synced.slug) if synced

    feature_slug = feature_slug_for_provider(provider)
    return feature_slug if feature_slug.present?

    provider_default_slug(provider)
  end

  # Last-resort slug for a provider with no synced or feature model. The
  # OpenAI-shaped @fallback_model (gpt-*) is only safe when the provider is
  # actually OpenAI; for other providers we pick the first registry model that
  # belongs to them, falling back to @fallback_model only if none exists.
  def provider_default_slug(provider)
    provider = normalized_provider(provider)
    return @fallback_model if provider == 'openai'

    Llm::Models.models.find { |_slug, meta| normalized_provider(meta['provider']) == provider }&.first || @fallback_model
  end

  def feature_slug_for_provider(provider)
    return nil if @feature.blank?

    default = Llm::Models.default_model_for(@feature)
    return default if default.present? && normalized_provider(Llm::Models.models.dig(default, 'provider')) == normalized_provider(provider)

    Llm::Models.models_for(@feature).find { |slug| normalized_provider(Llm::Models.models.dig(slug, 'provider')) == normalized_provider(provider) }
  end

  def active_credentials
    @active_credentials ||= @account.platform_credentials.active.to_a
  end

  def supported_active_credentials
    @supported_active_credentials ||= active_credentials.select do |credential|
      Llm::Config::SUPPORTED_RUNTIME_PROVIDERS.include?(normalized_provider(credential.provider))
    end
  end

  def normalized_provider(provider)
    provider.to_s == 'google' ? 'gemini' : provider.to_s
  end

  def canonical_slug(slug)
    Llm::Models.canonical_model_slug(slug)
  end

  def enabled_scope
    Platform::CredentialModel.enabled
                             .joins(:credential)
                             .where(platform_credentials: { account_id: @account.id })
                             .merge(Platform::Credential.active)
                             .order(:kind, :display_name, :id)
  end
end
