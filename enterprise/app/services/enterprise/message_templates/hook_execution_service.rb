module Enterprise::MessageTemplates::HookExecutionService
  MAX_ATTACHMENT_WAIT_SECONDS = 4

  def trigger_templates
    super
    return if skip_service_channel_conversation?
    return unless should_process_captain_response?
    return perform_handoff unless conversation.resolved_captain_active?

    schedule_captain_response
  end

  def should_send_greeting?
    return false if captain_handling_conversation?

    super
  end

  def should_send_out_of_office_message?
    return false if captain_handling_conversation?

    super
  end

  def should_send_email_collect?
    return false if captain_handling_conversation?

    super
  end

  private

  # The channel provider's own service contact (QR/status notifications
  # arriving as fake incoming messages, e.g. Evolution's +123456) must never
  # reach Captain: no response, no handoff, no auto-resolution. It is not a
  # customer conversation. See Conversation#service_channel_conversation?.
  def skip_service_channel_conversation?
    return false unless conversation.service_channel_conversation?

    Rails.logger.info(
      "[CAPTAIN][skip] account=#{conversation.account_id} conversation=#{conversation.display_id} reason=service_contact"
    )
    true
  end

  # The job is enqueued immediately — no Sidekiq `wait:`, which used to add
  # its scheduled-set poller latency (2.5-7.5s for a 2s wait, see docs/adaki/
  # captain-plan-latencia-2026-09.md fase 1) on top of every debounce. The
  # debounce itself (coalescing a customer's message burst into one LLM run)
  # now happens as a plain sleep inside the job: when the customer sends a
  # burst, all but the last job's sleep sees a newer message and stands down
  # (ResponseBuilderJob#superseded_by_newer_message?), so only the last one
  # answers the whole burst. Set the env var to 0 to reply immediately to
  # each message, as before.
  def schedule_captain_response
    job_args = [conversation, conversation.resolved_captain_assistant]
    wait_time = captain_debounce_wait
    wait_time += calculate_attachment_wait_time if message.attachments.present?

    Captain::Conversation::ResponseBuilderJob.perform_later(*job_args, debounce_wait: wait_time.to_f)
  end

  def captain_debounce_wait
    seconds = ENV.fetch('CAPTAIN_RESPONSE_DEBOUNCE_SECONDS', 2).to_f
    seconds.positive? ? seconds.seconds : 0.seconds
  end

  def calculate_attachment_wait_time
    attachment_count = message.attachments.size
    base_wait = 1.second

    # Wait longer for more attachments or larger files
    additional_wait = [attachment_count * 1, MAX_ATTACHMENT_WAIT_SECONDS].min.seconds
    base_wait + additional_wait
  end

  def should_process_captain_response?
    conversation_captain_controllable? && message.incoming? && captain_autopilot_enabled?
  end

  def perform_handoff
    return unless conversation_captain_controllable?

    Rails.logger.info("Captain limit exceeded, performing handoff mid-conversation for conversation: #{conversation.id}")
    conversation.messages.create!(
      message_type: :outgoing,
      account_id: conversation.account.id,
      inbox_id: conversation.inbox.id,
      content: 'Transferring to another agent for further assistance.'
    )
    conversation.bot_handoff!
    send_out_of_office_message_after_handoff
  end

  def send_out_of_office_message_after_handoff
    # Campaign conversations should never receive OOO templates — the campaign itself
    # serves as the initial outreach, and OOO would be confusing in that context.
    return if conversation.campaign.present?

    ::MessageTemplates::Template::OutOfOffice.perform_if_applicable(conversation)
  end

  def captain_handling_conversation?
    conversation_captain_controllable? && captain_autopilot_enabled?
  end

  def captain_autopilot_enabled?
    conversation.resolved_captain_assistant.present? &&
      conversation.resolved_captain_assistant.autopilot_enabled?
  end

  def conversation_captain_controllable?
    return false unless conversation.pending? || conversation.open?

    !human_takeover?
  end

  def human_takeover?
    Captain::HumanTakeoverEvaluator.new(conversation: conversation).human_takeover?
  end
end
