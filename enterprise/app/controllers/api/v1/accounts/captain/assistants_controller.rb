class Api::V1::Accounts::Captain::AssistantsController < Api::V1::Accounts::BaseController
  before_action :current_account
  before_action :authorize_captain_assistant, except: [:generate_config]
  before_action :check_admin_for_generate_config, only: [:generate_config]

  before_action :set_assistant, only: [:show, :update, :destroy, :playground, :generate_config]

  def index
    @assistants = account_assistants.ordered
  end

  def show; end

  def create
    @assistant = account_assistants.create!(assistant_params)
  end

  def update
    attrs = assistant_params.to_h
    # config es jsonb — el update! lo REEMPLAZA entero. Hacer merge manual evita
    # que un payload parcial (e.g. AI config panel mandando solo handoff/resolution
    # message) descarte keys críticas como autopilot_enabled, product_name, etc.
    if attrs[:config].present?
      attrs[:config] = (@assistant.config || {}).merge(attrs[:config].stringify_keys)
    end
    @assistant.update!(attrs)
  end

  def destroy
    @assistant.destroy
    head :no_content
  end

  def playground
    response = if captain_v2_enabled?
                 Captain::Assistant::AgentRunnerService.new(assistant: @assistant, source: 'playground').generate_response(
                   message_history: playground_message_history
                 )
               else
                 Captain::Llm::AssistantChatService.new(assistant: @assistant, source: 'playground').generate_response(
                   additional_message: playground_params[:message_content],
                   message_history: message_history
                 )
               end

    render json: response
  end

  def generate_config
    allowed_fields = Captain::Llm::AssistantConfigGeneratorService::ALLOWED_FIELDS
    fields = Array(params[:fields]).select { |f| allowed_fields.include?(f) }
    fields = allowed_fields if fields.empty?

    result = Captain::Llm::AssistantConfigGeneratorService.new(
      account: Current.account,
      assistant: @assistant,
      fields: fields
    ).perform

    if result[:error]
      render json: { error: result[:error] }, status: (result[:error_code] || :unprocessable_entity)
    else
      payload = result[:message]
      create_generated_scenarios(payload.delete(:scenarios))
      render json: payload
    end
  rescue StandardError => e
    Rails.logger.error("[AssistantConfigGenerator] #{e.class}: #{e.message}")
    render json: { error: "Failed to generate config: #{e.message}" }, status: :bad_request
  end

  def tools
    assistant = Captain::Assistant.new(account: Current.account)
    @tools = assistant.available_agent_tools
  end

  private

  def authorize_captain_assistant
    check_authorization(Captain::Assistant)
  end

  def check_admin_for_generate_config
    raise Pundit::NotAuthorizedError unless Current.account_user&.administrator?
  end

  def create_generated_scenarios(scenarios)
    return if scenarios.blank?

    scenarios.each do |s|
      @assistant.scenarios.create!(
        title: s[:title],
        description: s[:description].presence || s[:title],
        instruction: s[:instruction],
        account: Current.account
      )
    rescue StandardError => e
      Rails.logger.warn("[AssistantConfigGenerator] Skipping scenario '#{s[:title]}': #{e.message}")
    end
  end

  def set_assistant
    @assistant = account_assistants.find(params[:id])
  end

  def account_assistants
    @account_assistants ||= Captain::Assistant.for_account(Current.account.id)
  end

  def assistant_params
    permitted = params.require(:assistant).permit(:name, :description,
                                                  config: [
                                                    :product_name, :feature_faq, :feature_memory, :feature_citation,
                                                    :feature_contact_attributes,
                                                    :welcome_message, :handoff_message, :resolution_message,
                                                    :instructions, :temperature, :autopilot_enabled, :group_trigger,
                                                    :whatsapp_number,
                                                    :auto_handoff_enabled, :auto_resolve_hours, :continue_after_human_takeover,
                                                    :human_takeover_mode, :human_takeover_window_minutes
                                                  ])

    # Handle array parameters separately to allow partial updates
    permitted[:response_guidelines] = params[:assistant][:response_guidelines] if params[:assistant].key?(:response_guidelines)

    permitted[:guardrails] = params[:assistant][:guardrails] if params[:assistant].key?(:guardrails)

    permitted
  end

  def playground_params
    params.require(:assistant).permit(:message_content, message_history: [:role, :content, :agent_name])
  end

  def message_history
    (playground_params[:message_history] || []).map do |message|
      {
        role: message[:role],
        content: message[:content],
        agent_name: message[:agent_name]
      }.compact
    end
  end

  def playground_message_history
    history = message_history
    current_message = playground_params[:message_content]
    return history if current_message.blank?

    current_user_message = { role: 'user', content: current_message }
    return history if history.last == current_user_message

    history + [current_user_message]
  end

  def captain_v2_enabled?
    @assistant.account.feature_enabled?('captain_integration_v2')
  end
end
