class AgentBotPolicy < ApplicationPolicy
  def index?
    @account_user.administrator? || @account_user.agent?
  end

  def update?
    administrator_or_custom_role_permission?('agent_bot_manage')
  end

  def show?
    @account_user.administrator? || @account_user.agent?
  end

  def create?
    administrator_or_custom_role_permission?('agent_bot_manage')
  end

  def destroy?
    administrator_or_custom_role_permission?('agent_bot_manage')
  end

  def avatar?
    administrator_or_custom_role_permission?('agent_bot_manage')
  end

  def reset_access_token?
    administrator_or_custom_role_permission?('agent_bot_manage')
  end

  def reset_secret?
    administrator_or_custom_role_permission?('agent_bot_manage')
  end
end
