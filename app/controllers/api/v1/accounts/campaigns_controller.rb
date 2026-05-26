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

  # Endpoint para Generación de Variaciones y Mensajes con IA
  def ai_generate
    result = generate_campaign_copy(
      prompt: params[:prompt].to_s,
      tone: params[:tone].presence || 'friendly',
      goal: params[:goal].presence || 'informative'
    )

    render json: result
  rescue JSON::ParserError => e
    render json: { error: "Invalid AI response: #{e.message}" }, status: :bad_request
  rescue CustomExceptions::Platform::MissingCredential
    render json: { error: 'OpenAI credential not configured.' }, status: :unprocessable_entity
  rescue StandardError => e
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

  def generate_campaign_copy(prompt:, tone:, goal:)
    system_prompt = <<~PROMPT
      You are a senior campaign copywriter.
      Return strict JSON only with this schema:
      {
        "message": "Main message",
        "variants": [
          { "text": "Variant 1" },
          { "text": "Variant 2" },
          { "text": "Variant 3" }
        ]
      }
      Write for human review, keep the tone consistent, and keep the text concise.
      Use Liquid variables only when relevant, such as {{contact.name}}.
    PROMPT

    credential_key = Platform::CredentialManager.default_key_for('openai')

    Platform::CredentialManager.with_credential_context(
      account: Current.account,
      key: credential_key,
      provider: 'openai',
      purpose: 'ai_provider'
    ) do |context, _credential|
      chat = context.chat(model: Llm::Config::DEFAULT_MODEL)
      chat.with_instructions(system_prompt)
      response = chat.ask("Goal: #{goal}\nTone: #{tone}\nBrief: #{prompt}")
      normalize_ai_payload(response.content)
    end
  end

  def normalize_ai_payload(content)
    cleaned_content = content.to_s.strip
    cleaned_content = cleaned_content.sub(/\A```(?:json)?\s*/i, '')
    cleaned_content = cleaned_content.sub(/\s*```\z/, '')

    parsed = JSON.parse(cleaned_content)
    message = parsed['message'].to_s.strip
    variants = Array(parsed['variants']).filter_map do |variant|
      text = variant.is_a?(Hash) ? variant['text'] : variant
      text = text.to_s.strip
      next if text.blank?

      { text: text }
    end

    {
      message: message,
      variants: variants
    }
  end
end
