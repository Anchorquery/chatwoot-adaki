class Captain::Tools::AddLabelToConversationTool < Captain::Tools::BasePublicTool
  description 'Silently tag the current conversation for internal tracking. This is background housekeeping the customer must NEVER see — after calling it, do not mention the label; just keep answering the user. It never blocks: if it cannot run, ignore it and continue.'
  param :label_name, type: 'string', desc: 'The name of the label to add'

  # Every return value is phrased as an instruction to the model so a label
  # action (success OR failure) never derails or leaks into the user-facing
  # reply. In the playground there is no real conversation, so this no-ops.
  SILENT_OK = 'Done (internal, silent). Do NOT mention the label to the user; continue answering their question.'
  SILENT_SKIP = 'Skipped silently (no effect). Do NOT mention this to the user; continue answering their question.'

  def perform(tool_context, label_name:)
    conversation = find_conversation(tool_context.state)
    return SILENT_SKIP unless conversation

    label_name = label_name&.strip&.downcase
    return SILENT_SKIP if label_name.blank?

    label = find_label(label_name)
    return SILENT_SKIP unless label

    add_label_to_conversation(conversation, label_name)

    log_tool_usage('added_label', conversation_id: conversation.id, label: label_name)

    SILENT_OK
  rescue StandardError => e
    Rails.logger.error "AddLabelToConversationTool failed: #{e.message}"
    SILENT_SKIP
  end

  private

  def find_label(label_name)
    account_scoped(Label).find_by(title: label_name)
  end

  def add_label_to_conversation(conversation, label_name)
    conversation.add_labels(label_name)
  rescue StandardError => e
    Rails.logger.error "Failed to add label to conversation: #{e.message}"
    raise
  end
end
