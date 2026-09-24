class InboxPolicy < ApplicationPolicy
  class Scope
    attr_reader :user_context, :user, :scope, :account, :account_user

    def initialize(user_context, scope)
      @user_context = user_context
      @user = user_context[:user]
      @account = user_context[:account]
      @account_user = user_context[:account_user]
      @scope = scope
    end

    def resolve
      return account.inboxes if account_user.permissions.include?('agent_settings_manage')

      user.assigned_inboxes
    end
  end

  def index?
    true
  end

  def show?
    # FIXME: for agent bots, lets bring this validation to policies as well in future
    return true if @user.is_a?(AgentBot) || agent_settings_manager?

    Current.user.assigned_inboxes.include? record
  end

  def assignable_agents?
    true
  end

  def agent_bot?
    true
  end

  def campaigns?
    administrator_or_custom_role_permission?('campaign_manage')
  end

  def create?
    agent_settings_manager?
  end

  def update?
    agent_settings_manager?
  end

  def destroy?
    agent_settings_manager?
  end

  def set_agent_bot?
    agent_settings_manager?
  end

  def avatar?
    agent_settings_manager?
  end

  def sync_templates?
    agent_settings_manager?
  end

  def health?
    agent_settings_manager?
  end

  def reset_secret?
    agent_settings_manager?
  end

  def evolution_audience_options?
    agent_settings_manager?
  end

  def evolution_test_connection?
    agent_settings_manager?
  end

  def evolution_privacy_filter?
    agent_settings_manager? || Current.user.assigned_inboxes.include?(record)
  end

  def evolution_update_privacy_filter?
    agent_settings_manager? || Current.user.assigned_inboxes.include?(record)
  end

  private

  def agent_settings_manager?
    administrator_or_custom_role_permission?('agent_settings_manage')
  end
end
