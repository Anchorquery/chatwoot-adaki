class Api::V1::Accounts::Platform::CredentialsController < Api::V1::Accounts::BaseController
  before_action :current_account
  before_action :set_credential, only: %i[show update destroy validate rotate revoke usages]
  before_action :authorize_account_update
  # Adding/removing/revoking a credential can change the account's resolved
  # embedding provider (e.g. the Gemini fallback kicks in once a gemini
  # credential exists); reconcile so vectors get re-indexed to match.
  after_action :reconcile_embeddings, only: %i[create update destroy revoke]

  def index
    render json: credentials.map { |credential| serialize_credential(credential) }
  end

  def show
    render json: serialize_credential(@credential)
  end

  def create
    return render json: provider_disabled_error, status: :unprocessable_entity unless provider_allowed?(credential_params[:provider])

    credential = Platform::CredentialManager.store!(
      account: @current_account,
      provider: credential_params[:provider],
      purpose: credential_params[:purpose],
      key: credential_key,
      name: credential_params[:name],
      auth_type: credential_params[:auth_type],
      payload: credential_params[:payload].to_h,
      metadata: credential_params[:metadata].to_h,
      owner: nil,
      user: Current.user
    )

    render json: serialize_credential(credential), status: :created
  end

  def update
    new_provider = credential_params[:provider]
    provider_changed = new_provider.present? && new_provider != @credential.provider

    return render json: provider_disabled_error, status: :unprocessable_entity if provider_changed && !provider_allowed?(new_provider)

    payload = credential_payload
    metadata = credential_metadata

    @credential.update!(
      provider: new_provider,
      purpose: credential_params[:purpose],
      key: credential_params[:key].presence || @credential.key,
      name: credential_params[:name],
      auth_type: credential_params[:auth_type],
      payload: payload.nil? ? @credential.payload : payload,
      metadata: metadata.nil? ? @credential.metadata : metadata,
      updated_by: Current.user
    )

    render json: serialize_credential(@credential)
  end

  def destroy
    @credential.destroy!
    head :ok
  end

  def rotate
    credential = Platform::CredentialManager.rotate!(
      credential: @credential,
      payload: credential_params[:payload].to_h,
      user: Current.user
    )

    render json: serialize_credential(credential)
  end

  def revoke
    credential = Platform::CredentialManager.revoke!(credential: @credential, user: Current.user)
    render json: serialize_credential(credential)
  end

  def validate
    credential = Platform::CredentialManager.validate!(credential: @credential)
    render json: serialize_credential(credential)
  end

  def usages
    render json: @credential.platform_credential_usages.order(created_at: :desc).map do |usage|
      {
        id: usage.id,
        operation: usage.operation,
        status: usage.status,
        error_code: usage.error_code,
        context: usage.context,
        created_at: usage.created_at
      }
    end
  end

  private

  def reconcile_embeddings
    return unless defined?(Captain::Embeddings::Manager)

    Captain::Embeddings::Manager.reconcile!(@current_account)
  rescue StandardError => e
    Rails.logger.error("[Captain::Embeddings] reconcile failed: #{e.message}")
  end

  def authorize_account_update
    authorize @current_account, :update?
  end

  def set_credential
    @credential = @current_account.platform_credentials.find(params[:id])
  end

  def credentials
    @current_account.platform_credentials.order(created_at: :desc)
  end

  def serialize_credential(credential)
    {
      id: credential.id,
      name: credential.name,
      key: credential.key,
      provider: credential.provider,
      purpose: credential.purpose,
      auth_type: credential.auth_type,
      status: credential.status,
      token_hint: credential.token_hint,
      metadata: credential.metadata,
      last_used_at: credential.last_used_at,
      last_validated_at: credential.last_validated_at,
      expires_at: credential.expires_at,
      created_at: credential.created_at,
      updated_at: credential.updated_at
    }
  end

  def credential_params
    params.require(:credential).permit(
      :provider,
      :purpose,
      :name,
      :key,
      :auth_type,
      payload: {},
      metadata: {}
    ).to_h.with_indifferent_access
  end

  def credential_payload
    return nil unless credential_params.key?(:payload)

    credential_params[:payload].to_h
  end

  def credential_metadata
    return nil unless credential_params.key?(:metadata)

    credential_params[:metadata].to_h
  end

  def credential_key
    credential_params[:key].presence || Platform::CredentialManager.default_key_for(credential_params[:provider])
  end

  def provider_allowed?(provider)
    Llm::Models.provider_enabled?(provider)
  end

  def provider_disabled_error
    {
      error: "Provider '#{credential_params[:provider]}' is not enabled yet. Available providers: OpenAI, Google Gemini and DeepSeek."
    }
  end
end
