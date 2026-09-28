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

  def update
    @scenario.update!(scenario_params)
  end

  def destroy
    @scenario.destroy
    head :no_content
  end

  def generate
    prompt = params.require(:prompt)
    result = Captain::Llm::ScenarioGeneratorService.new(
      account: Current.account,
      assistant: @assistant,
      prompt: prompt
    ).perform

    if result[:error]
      render json: { error: result[:error] }, status: result[:error_code] || :unprocessable_entity
    else
      render json: result[:message], status: :ok
    end
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
end
