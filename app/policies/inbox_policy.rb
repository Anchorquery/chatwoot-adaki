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
      return account.inboxes if account_user.permissions.include?('inbox_manage')

      user.assigned_inboxes
    end
  end

  def index?
    true
  end

  def show?
    # FIXME: for agent bots, lets bring this validation to policies as well in future
    return true if @user.is_a?(AgentBot) || inbox_manager?

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
    inbox_manager?
  end

  def update?
    inbox_manager?
  end

  def destroy?
    inbox_manager?
  end

  def set_agent_bot?
    inbox_manager?
  end

  def avatar?
    inbox_manager?
  end

  def sync_templates?
    inbox_manager?
  end

  def health?
    inbox_manager?
  end

  def reset_secret?
    inbox_manager?
  end

  def whatsapp_tier?
    inbox_manager?
  end

  def evolution_audience_options?
    inbox_manager?
  end

  def evolution_test_connection?
    inbox_manager?
  end

  def evolution_create?
    inbox_manager?
  end

  def evolution_connection_state?
    inbox_manager? || channel_operator?
  end

  def evolution_connect?
    inbox_manager? || channel_operator?
  end

  def evolution_logout?
    inbox_manager?
  end

  def evolution_restart?
    inbox_manager? || channel_operator?
  end

  def evolution_instance_settings?
    inbox_manager?
  end

  def evolution_update_instance_settings?
    inbox_manager?
  end

  def evolution_privacy_filter?
    inbox_manager? || Current.user.assigned_inboxes.include?(record)
  end

  def evolution_update_privacy_filter?
    inbox_manager? || Current.user.assigned_inboxes.include?(record)
  end

  private

  def inbox_manager?
    administrator_or_custom_role_permission?('inbox_manage')
  end

  # 'channel_operate' connects (QR), checks and restarts the WhatsApp session,
  # but only of the inboxes the user is assigned to.
  def channel_operator?
    administrator_or_custom_role_permission?('channel_operate') &&
      Current.user.assigned_inboxes.include?(record)
  end
end
