module Enterprise::Api::V1::Accounts::AgentsController
  def create
    authorize_role_assignment!
    super
    associate_agent_with_custom_role
  end

  def update
    authorize_role_assignment!
    super
    associate_agent_with_custom_role
  end

  private

  def associate_agent_with_custom_role
    custom_role = Current.account.custom_roles.find(params[:custom_role_id]) if params[:custom_role_id].present?
    @agent.current_account_user.update!(custom_role: custom_role)
  end

  def authorize_role_assignment!
    return if Current.account_user.administrator?

    return unless Current.account_user.permissions.include?('agent_settings_manage')

    role = params.dig(:agent, :role) || params[:role]
    return unless role == 'administrator'

    raise Pundit::NotAuthorizedError
  end
end
