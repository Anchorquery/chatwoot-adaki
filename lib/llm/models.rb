module Llm::Models
  CONFIG = YAML.load_file(Rails.root.join('config/llm.yml')).freeze
  # Slugs the provider RETIRED. A stored value pointing at one of these is
  # provably not what the provider serves any more, so it is remapped
  # everywhere — including rows in platform_credential_models, which are
  # otherwise authoritative (see Platform::Models::Resolver).
  # DeepSeek retired its two aliases on 2026-07-24; Google shut down
  # gemini-3-pro-preview (checked against ai.google.dev on 2026-09-06, where it
  # is listed under shut-down models). Both reroute to the provider's current
  # equivalent so a stored preference or a stale synced row keeps working.
  RETIRED_MODEL_ALIASES = {
    'deepseek-chat' => 'deepseek-v4-flash',
    'deepseek-reasoner' => 'deepseek-v4-pro',
    'gemini-3-pro-preview' => 'gemini-3.1-pro-preview'
  }.freeze

  # Shorthand this catalog and the model dropdown have used for slugs whose
  # real provider id is longer. These describe OUR naming, not the provider's,
  # so they are only ever applied to catalog entries and stored preferences —
  # never to a slug synced from the provider's live model list, which would
  # rewrite a valid id into one the provider may not serve.
  CATALOG_MODEL_ALIASES = {
    'gemini-3-flash' => 'gemini-3-flash-preview',
    # Points at the current pro model, not the shut-down preview it named when
    # this shorthand was introduced.
    'gemini-3-pro' => 'gemini-3.1-pro-preview'
  }.freeze

  MODEL_ALIASES = RETIRED_MODEL_ALIASES.merge(CATALOG_MODEL_ALIASES).freeze

  class << self
    def providers = CONFIG['providers']
    def models = CONFIG['models']
    def features = CONFIG['features']
    def feature_keys = CONFIG['features'].keys

    def enabled_providers
      CONFIG['providers'].select { |_k, meta| meta['enabled'] != false }
    end

    def provider_enabled?(provider)
      meta = CONFIG['providers'][provider.to_s]
      return false unless meta

      meta['enabled'] != false
    end

    # For catalog entries and stored user preferences.
    def canonical_model_slug(model_name)
      return model_name if model_name.nil? || model_name.to_s.empty?

      MODEL_ALIASES.fetch(model_name.to_s, model_name.to_s)
    end

    # For slugs that came from the provider itself (platform_credential_models).
    # Only rewrites endpoints the provider retired; anything else is passed
    # through untouched because the provider, not this catalog, is the
    # authority on what it serves.
    def current_model_slug(model_name)
      return model_name if model_name.nil? || model_name.to_s.empty?

      RETIRED_MODEL_ALIASES.fetch(model_name.to_s, model_name.to_s)
    end

    def default_model_for(feature)
      canonical_model_slug(CONFIG.dig('features', feature.to_s, 'default'))
    end

    def models_for(feature)
      (CONFIG.dig('features', feature.to_s, 'models') || []).map { |model| canonical_model_slug(model) }.uniq
    end

    def valid_model_for?(feature, model_name)
      models_for(feature).include?(canonical_model_slug(model_name))
    end

    def feature_config(feature_key)
      feature = features[feature_key.to_s]
      return nil unless feature

      {
        models: feature['models'].map do |model_name|
          model_name = canonical_model_slug(model_name)
          model = models[model_name]
          {
            id: model_name,
            display_name: model['display_name'],
            provider: model['provider'],
            coming_soon: model['coming_soon'],
            credit_multiplier: model['credit_multiplier']
          }
        end,
        default: feature['default']
      }
    end
  end
end
