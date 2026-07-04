class Api::V1::Accounts::Captain::PreferencesController < Api::V1::Accounts::BaseController
  before_action :current_account
  before_action :authorize_account_update, only: [:update]

  def show
    render json: preferences_payload
  end

  def update
    params_to_update = captain_params
    @current_account.captain_models = params_to_update[:captain_models] if params_to_update[:captain_models]
    @current_account.captain_features = params_to_update[:captain_features] if params_to_update[:captain_features]
    @current_account.save!

    reconcile_embeddings

    render json: preferences_payload
  end

  private

  FEATURE_MODEL_KINDS = {
    'editor' => %w[chat multimodal],
    'assistant' => %w[chat multimodal],
    'copilot' => %w[chat multimodal],
    'label_suggestion' => %w[chat multimodal],
    'audio_transcription' => %w[transcription multimodal],
    'help_center_search' => %w[embedding],
    # PDF -> FAQ generation needs a vision-capable model; chat models are also
    # offered for OpenAI (its Files API attaches the PDF to a chat call).
    'document_faq' => %w[multimodal chat]
  }.freeze

  # When the embedding model selection changes, reconcile re-indexes the
  # account's vectors and flips the active embedding model pointer.
  def reconcile_embeddings
    return unless defined?(Captain::Embeddings::Manager)

    Captain::Embeddings::Manager.reconcile!(@current_account)
  rescue StandardError => e
    Rails.logger.error("[Captain::Embeddings] reconcile failed: #{e.message}")
  end

  def preferences_payload
    {
      providers: Llm::Models.providers,
      models: Llm::Models.models,
      features: features_with_account_preferences
    }
  end

  def authorize_account_update
    authorize @current_account, :update?
  end

  def captain_params
    permitted = {}
    permitted[:captain_models] = merged_captain_models if params[:captain_models].present?
    permitted[:captain_features] = merged_captain_features if params[:captain_features].present?
    permitted
  end

  def merged_captain_models
    existing_models = @current_account.captain_models || {}
    existing_models.merge(permitted_captain_models)
  end

  def merged_captain_features
    existing_features = @current_account.captain_features || {}
    existing_features.merge(permitted_captain_features)
  end

  def permitted_captain_models
    params.require(:captain_models).permit(
      :editor, :assistant, :copilot, :label_suggestion,
      :audio_transcription, :help_center_search, :document_faq
    ).to_h.stringify_keys
  end

  def permitted_captain_features
    params.require(:captain_features).permit(
      :editor, :assistant, :copilot, :label_suggestion,
      :audio_transcription, :help_center_search, :document_faq
    ).to_h.stringify_keys
  end

  def features_with_account_preferences
    preferences = Current.account.captain_preferences
    account_features = preferences[:features] || {}
    account_models = preferences[:models] || {}

    all_platform_models = platform_models_for_captain
    account_providers = account_credential_providers

    Llm::Models.feature_keys.index_with do |feature_key|
      config = Llm::Models.feature_config(feature_key)
      kinds = FEATURE_MODEL_KINDS[feature_key.to_s] || []
      yaml_slugs = config[:models].map { |m| m[:id] }

      extra_models = all_platform_models
                     .select { |m| kinds.include?(m.kind) && !yaml_slugs.include?(m.slug) }
                     .map do |m|
        {
          id: m.slug,
          display_name: "#{m.display_name} (#{m.credential.name})",
          provider: m.credential.provider,
          coming_soon: false,
          credit_multiplier: nil
        }
      end

      # When the account has its own provider credentials, hide catalog (YAML)
      # models from providers the account has not configured — they would fail
      # at runtime. Accounts without credentials keep the full catalog (legacy
      # global InstallationConfig setup).
      visible_yaml_models = if account_providers.any?
                              config[:models].select { |m| account_providers.include?(normalize_provider(m[:provider])) }
                            else
                              config[:models]
                            end

      models = visible_yaml_models + extra_models
      selected = account_models[feature_key] || config[:default]
      selected = models.reject { |m| m[:coming_soon] }.first&.dig(:id) if models.none? { |m| m[:id] == selected }

      config.merge(
        models: models,
        enabled: account_features[feature_key] == true,
        selected: selected
      )
    end
  end

  def account_credential_providers
    @account_credential_providers ||= @current_account.platform_credentials
                                                      .active
                                                      .pluck(:provider)
                                                      .map { |provider| normalize_provider(provider) }
                                                      .uniq
  end

  def normalize_provider(provider)
    provider = provider.to_s
    provider == 'google' ? 'gemini' : provider
  end

  def platform_models_for_captain
    Platform::CredentialModel
      .enabled
      .joins(:credential)
      .where(platform_credentials: { account_id: @current_account.id })
      .merge(Platform::Credential.active)
      .includes(:credential)
      .order(:kind, :display_name)
  end
end
