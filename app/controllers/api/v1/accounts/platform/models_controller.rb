class Api::V1::Accounts::Platform::ModelsController < Api::V1::Accounts::BaseController
  before_action :current_account
  before_action :authorize_account_update
  before_action :set_credential
  before_action :set_model, only: %i[show update destroy toggle]
  # Enabling/disabling an embedding model can change the account's selected
  # embedding provider; reconcile (re-index if needed) after such changes.
  after_action :reconcile_embeddings, only: %i[create update destroy toggle bulk_toggle]

  def index
    scope = @credential.models
    scope = scope.by_kind(params[:kind]) if params[:kind].present?
    scope = scope.where('display_name ILIKE ? OR slug ILIKE ?', "%#{params[:q]}%", "%#{params[:q]}%") if params[:q].present?
    render json: scope.order(:kind, :display_name).map { |m| serialize(m) }
  end

  def show
    render json: serialize(@model)
  end

  def create
    model = @credential.models.create!(model_params)
    render json: serialize(model), status: :created
  end

  def update
    @model.update!(model_params)
    render json: serialize(@model)
  end

  def destroy
    @model.destroy!
    head :ok
  end

  def toggle
    @model.update!(enabled: !@model.enabled)
    render json: serialize(@model)
  end

  def sync
    imported = Platform::Models::Importer.new(@credential).sync_remote!
    render json: { imported: imported.size }
  rescue Platform::Models::Importer::SyncError => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  def bulk_toggle
    enabled = ActiveModel::Type::Boolean.new.cast(params[:enabled])
    scope = @credential.models
    scope = scope.by_kind(params[:kind]) if params[:kind].present?
    scope.update_all(enabled: enabled, updated_at: Time.current)
    render json: { updated: scope.count }
  end

  private

  def authorize_account_update
    authorize @current_account, :update?
  end

  def reconcile_embeddings
    return unless defined?(Captain::Embeddings::Manager)

    Captain::Embeddings::Manager.reconcile!(@current_account)
  rescue StandardError => e
    Rails.logger.error("[Captain::Embeddings] reconcile failed: #{e.message}")
  end

  def set_credential
    @credential = @current_account.platform_credentials.find(params[:credential_id])
  end

  def set_model
    @model = @credential.models.find(params[:id])
  end

  def model_params
    permitted = params.require(:model).permit(
      :slug, :display_name, :kind, :context_window, :max_output_tokens,
      :input_price_per_million, :output_price_per_million, :data_cutoff_at,
      :description, :obsolete, :enabled,
      capabilities: [],
      reasoning_config: [{ supported_efforts: [] }]
    )
    return permitted unless permitted.key?(:reasoning_config)

    # An operator's edit is authoritative: it overrides both the family seed
    # and whatever the provider taught us (see Llm::ReasoningCapabilities).
    efforts = Array(permitted[:reasoning_config][:supported_efforts]).map(&:to_s)
    permitted[:reasoning_config] = {
      'supported_efforts' => efforts,
      'source' => 'manual',
      'updated_by_id' => Current.user&.id,
      'updated_at' => Time.current.iso8601
    }
    permitted
  end

  def serialize(model)
    {
      id: model.id,
      credential_id: model.credential_id,
      slug: model.slug,
      display_name: model.display_name,
      kind: model.kind,
      capabilities: model.capabilities,
      context_window: model.context_window,
      max_output_tokens: model.max_output_tokens,
      input_price_per_million: model.input_price_per_million,
      output_price_per_million: model.output_price_per_million,
      data_cutoff_at: model.data_cutoff_at,
      description: model.description,
      obsolete: model.obsolete,
      enabled: model.enabled,
      reasoning_config: model.reasoning_config,
      synced_at: model.synced_at,
      updated_at: model.updated_at
    }
  end
end
