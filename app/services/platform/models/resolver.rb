# Resolves the (credential, model_slug) pair to use at runtime for a given
# account/feature. Consults the new platform_credential_models table so the
# UI toggle is honored, with safe fallbacks for installs that have not
# enabled any model yet.
module Platform::Models
  class Resolver
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
      @preferred_slug = preferred_slug.to_s.presence
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
      return nil unless model

      { credential: model.credential, model_slug: model.slug, source: :preferred }
    end

    def resolve_by_feature
      return nil if @feature.blank?

      feature_models = Llm::Models.models_for(@feature)
      return nil if feature_models.blank?

      model = enabled_scope.where(slug: feature_models).first
      return nil unless model

      { credential: model.credential, model_slug: model.slug, source: :feature }
    end

    def resolve_by_kind
      return nil if @kind.blank?

      model = enabled_scope.where(kind: @kind).first
      return nil unless model

      { credential: model.credential, model_slug: model.slug, source: :kind }
    end

    def resolve_any_enabled
      model = enabled_scope.first
      return nil unless model

      { credential: model.credential, model_slug: model.slug, source: :any_enabled }
    end

    def resolve_fallback
      credential = @account.platform_credentials.active.first
      return nil unless credential

      slug = if @feature.present?
               Llm::Models.default_model_for(@feature).presence || @fallback_model
             else
               @fallback_model
             end

      { credential: credential, model_slug: slug, source: :fallback }
    end

    def enabled_scope
      Platform::CredentialModel.enabled
                               .joins(:credential)
                               .where(platform_credentials: { account_id: @account.id })
                               .merge(Platform::Credential.active)
                               .order(:kind, :display_name, :id)
    end
  end
end
