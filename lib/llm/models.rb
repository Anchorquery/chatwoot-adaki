module Llm::Models
  CONFIG = YAML.load_file(Rails.root.join('config/llm.yml')).freeze
  MODEL_ALIASES = {
    'gemini-3-flash' => 'gemini-3-flash-preview',
    'gemini-3-pro' => 'gemini-3-pro-preview',
    # DeepSeek retired these aliases on 2026-07-24. Keep existing account
    # preferences and credential-model rows working while routing them to the
    # current V4 endpoints.
    'deepseek-chat' => 'deepseek-v4-flash',
    'deepseek-reasoner' => 'deepseek-v4-pro'
  }.freeze

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

    def canonical_model_slug(model_name)
      return model_name if model_name.nil? || model_name.to_s.empty?

      MODEL_ALIASES.fetch(model_name.to_s, model_name.to_s)
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
