class Api::V1::Accounts::Captain::ScenariosController < Api::V1::Accounts::BaseController
  before_action :current_account
  before_action -> { check_authorization(Captain::Scenario) }
  before_action :set_assistant
  before_action :set_scenario, only: [:show, :update, :destroy]

  def index
    @scenarios = assistant_scenarios.enabled
  end

  def show; end

  def create
    @scenario = assistant_scenarios.create!(scenario_params.merge(account: Current.account))
  end

  def generate
    result = Captain::Llm::ScenarioGeneratorService.new(
      assistant: @assistant,
      focus: generation_focus,
      reference_scenarios: generation_reference_scenarios
    ).perform

    if result[:error]
      render json: { error: result[:error] }, status: (result[:error_code] || :unprocessable_entity)
      return
    end

    generated_value = result[:message].to_s.strip
    if generated_value.blank?
      render json: { error: 'Unable to generate scenario content.' }, status: :unprocessable_entity
      return
    end

    render json: { value: generated_value }
  rescue StandardError => e
    Rails.logger.error("[ScenarioGenerator] #{e.class}: #{e.message}")
    render json: { error: "Failed to generate scenario content: #{e.message}" }, status: :bad_request
  end

  def update
    @scenario.update!(scenario_params)
  end

  def destroy
    @scenario.destroy
    head :no_content
  end

  private

  def set_assistant
    @assistant = account_assistants.find(params[:assistant_id])
  end

  def account_assistants
    @account_assistants ||= Current.account.captain_assistants
  end

  def set_scenario
    @scenario = assistant_scenarios.find(params[:id])
  end

  def assistant_scenarios
    @assistant.scenarios
  end

  def scenario_params
    params.require(:scenario).permit(:title, :description, :instruction, :enabled, tools: [])
  end

  def generation_focus
    allowed_fields = %w[title description instruction]
    focus = params[:focus].to_s
    allowed_fields.include?(focus) ? focus : 'instruction'
  end

  def generation_reference_scenarios
    Array(params[:reference_scenarios]).filter_map do |scenario|
      next unless scenario.respond_to?(:to_h)

      scenario.to_h.symbolize_keys.slice(:title, :description, :instruction, :tools)
    end
  end
end
