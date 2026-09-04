module Enterprise::AgentNotifications::ConversationNotificationsMailer
  def sla_missed_first_response(conversation, agent, sla_policy)
    return unless smtp_config_set_or_development?

    @agent = agent
    @conversation = conversation
    @sla_policy = sla_policy
    subject = "Conversation [ID - #{@conversation.display_id}] missed SLA for first response"
    @action_url = app_account_conversation_url(account_id: @conversation.account_id, id: @conversation.display_id)
    send_mail_with_liquid(to: @agent.email, subject: subject) and return
  end

  def sla_missed_next_response(conversation, agent, sla_policy)
    return unless smtp_config_set_or_development?

    @agent = agent
    @conversation = conversation
    @sla_policy = sla_policy
    @action_url = app_account_conversation_url(account_id: @conversation.account_id, id: @conversation.display_id)
    send_mail_with_liquid(to: @agent.email, subject: "Conversation [ID - #{@conversation.display_id}] missed SLA for next response") and return
  end

  def sla_missed_resolution(conversation, agent, sla_policy)
    return unless smtp_config_set_or_development?

    @agent = agent
    @conversation = conversation
    @sla_policy = sla_policy
    @action_url = app_account_conversation_url(account_id: @conversation.account_id, id: @conversation.display_id)
    send_mail_with_liquid(to: @agent.email, subject: "Conversation [ID - #{@conversation.display_id}] missed SLA for resolution time") and return
  end

  # Sent by Captain::Conversation::UnattendedHandoffJob to every member of the
  # handoff team (or every inbox collaborator) when a Captain handoff is still
  # unassigned after the grace period. Deliberately not a Notification type:
  # it must reach people regardless of their personal notification settings.
  def captain_unattended_handoff(conversation, agent, _message = nil)
    return unless smtp_config_set_or_development?

    @agent = agent
    @conversation = conversation
    @action_url = app_account_conversation_url(account_id: @conversation.account_id, id: @conversation.display_id)
    subject = I18n.t(
      'conversations.captain.unattended_handoff_email.subject',
      name: @agent.available_name, id: @conversation.display_id, inbox: @conversation.inbox&.sanitized_name
    )
    send_mail_with_liquid(to: @agent.email, subject: subject) and return
  end

  def liquid_droppables
    super.merge({
                  sla_policy: @sla_policy
                })
  end

  def liquid_locals
    locals = super
    return locals unless action_name == 'captain_unattended_handoff'

    locals.merge(
      captain_unattended: {
        'intro' => I18n.t('conversations.captain.unattended_handoff_email.intro',
                          id: @conversation.display_id, inbox: @conversation.inbox&.name),
        'body' => I18n.t('conversations.captain.unattended_handoff_email.body',
                         contact: @conversation.contact&.name.presence || I18n.t('conversations.captain.unattended_handoff_email.customer')),
        'cta' => I18n.t('conversations.captain.unattended_handoff_email.cta')
      }
    )
  end
end
