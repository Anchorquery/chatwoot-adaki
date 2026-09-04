class Captain::Tools::HandoffTool < Captain::Tools::BasePublicTool
  GREETING_ONLY_PATTERN = /
    \A(?:hola|hello|hi|hey|buenas?|buenos\s+dias|buenas\s+tardes|buenas\s+noches)
    (?:\s+(?:hola|hello|hi|hey|buenas?|buenos\s+dias|buenas\s+tardes|buenas\s+noches))*\z
  /ix

  description 'Hand off the conversation to a human agent when unable to assist further'
  param :reason, type: 'string', desc: 'The reason why handoff is needed (optional)', required: false

  def perform(tool_context, reason: nil)
    conversation = find_conversation(tool_context.state)
    return 'Conversation not found' unless conversation

    if greeting_only?(conversation)
      log_tool_usage('handoff_rejected', { conversation_id: conversation.id, reason: 'greeting_only' })
      return 'Handoff skipped: the customer only greeted you. Greet them and ask how you can help.'
    end

    # Log the handoff with reason
    log_tool_usage('tool_handoff', {
                     conversation_id: conversation.id,
                     reason: reason || 'Agent requested handoff'
                   })

    # Use existing handoff mechanism from ResponseBuilderJob
    trigger_handoff(conversation, reason)

    "Conversation handed off to human support team#{" (Reason: #{reason})" if reason}"
  rescue StandardError => e
    ChatwootExceptionTracker.new(e).capture_exception
    'Failed to handoff conversation'
  end

  private

  def greeting_only?(conversation)
    text = conversation.messages.incoming.order(created_at: :desc).pick(:content).to_s
    normalized = I18n.transliterate(text).downcase.gsub(/[^\p{L}\p{N}\s]/, ' ').squeeze(' ').strip
    normalized.match?(GREETING_ONLY_PATTERN)
  end

  def trigger_handoff(conversation, reason)
    # post the reason as a private note
    conversation.messages.create!(
      message_type: :outgoing,
      private: true,
      sender: @assistant,
      account: conversation.account,
      inbox: conversation.inbox,
      content: reason
    )

    # Trigger the bot handoff (sets status to open + dispatches events)
    conversation.bot_handoff!

    # Send out of office message if applicable (since template messages were suppressed while Captain was handling)
    send_out_of_office_message_if_applicable(conversation)
  end

  def send_out_of_office_message_if_applicable(conversation)
    # Campaign conversations should never receive OOO templates — the campaign itself
    # serves as the initial outreach, and OOO would be confusing in that context.
    return if conversation.campaign.present?

    ::MessageTemplates::Template::OutOfOffice.perform_if_applicable(conversation)
  end

  # Team routing is applied by Conversation#bot_handoff! from the assistant or
  # inbox Captain configuration. Keeping it out of the LLM tool parameters
  # prevents the model from selecting arbitrary account teams.
end
