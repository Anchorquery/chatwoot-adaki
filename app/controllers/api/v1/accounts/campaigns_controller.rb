class Api::V1::Accounts::CampaignsController < Api::V1::Accounts::BaseController
  before_action :campaign, except: [:index, :create, :ai_generate]
  before_action :check_authorization
  before_action :parse_delivery_settings, only: [:create, :update]

  def index
    @campaigns = Current.account.campaigns
  end

  def show; end

  def create
    @campaign = Current.account.campaigns.new(campaign_params.except(:attachments))
    attach_files_to(@campaign)
    @campaign.save!
  end

  def update
    @campaign.update!(campaign_params.except(:attachments))
    remove_files_from(@campaign)
    attach_files_to(@campaign)
  end

  def destroy
    @campaign.destroy!
    head :ok
  end

  def ai_generate
    if params[:prompt].to_s.strip.blank?
      render json: { error: 'Prompt is required.' }, status: :bad_request
      return
    end

    allowed_styles = %w[concise standard detailed]
    allowed_context_sources = %w[none guidelines documents]
    style = allowed_styles.include?(params[:style]) ? params[:style] : 'standard'
    context_source = allowed_context_sources.include?(params[:context_source]) ? params[:context_source] : 'none'
    use_emojis = ActiveModel::Type::Boolean.new.cast(params[:use_emojis])
    assistant = Current.account.captain_assistants.find_by(id: params[:assistant_id])

    result = Captain::Llm::CampaignCopyService.new(
      account: Current.account,
      prompt: params[:prompt].to_s,
      tone: params[:tone].presence || 'friendly',
      goal: params[:goal].presence || 'informative',
      assistant: assistant,
      use_emojis: use_emojis,
      style: style,
      context_source: context_source
    ).perform

    if result[:error]
      render json: { error: result[:error] }, status: (result[:error_code] || :unprocessable_entity)
      return
    end

    render json: result[:message]
  rescue CustomExceptions::Platform::MissingCredential
    render json: { error: 'OpenAI credential not configured.' }, status: :unprocessable_entity
  rescue StandardError => e
    Rails.logger.error("[CampaignCopy] #{e.class}: #{e.message}")
    render json: { error: "Failed to generate campaign copy: #{e.message}" }, status: :bad_request
  end

  private

  def campaign
    @campaign ||= Current.account.campaigns.find_by(display_id: params[:id])
  end

  def attach_files_to(campaign)
    files = params.dig(:campaign, :attachments)
    return if files.blank?

    Array(files).each do |file|
      campaign.attachments.attach(file)
    end
  end

  def remove_files_from(campaign)
    attachment_ids = Array(params.dig(:campaign, :attachment_ids_to_remove)).reject(&:blank?)
    return if attachment_ids.blank?

    campaign.attachments_attachments.where(id: attachment_ids).each(&:purge)
  end

  def parse_delivery_settings
    raw = params.dig(:campaign, :delivery_settings)
    return unless raw.is_a?(String)

    params[:campaign][:delivery_settings] = JSON.parse(raw)
  rescue JSON::ParserError
    nil
  end

  def campaign_params
    params.require(:campaign).permit(
      :title, :description, :message, :enabled, :trigger_only_during_business_hours,
      :inbox_id, :sender_id, :scheduled_at, :requires_approval,
      audience: [:type, :id],
      trigger_rules: {},
      template_params: {},
      delivery_settings: {},
      attachment_ids_to_remove: [],
      attachments: []
    )
  end

end
