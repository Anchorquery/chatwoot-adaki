# See docs/adaki/captain-plan-latencia-2026-09.md fase 5.3: compresses the
# part of a conversation that has aged out of Captain::Conversation::
# HistoryBuilder's window into a short block HistoryBuilder can re-inject
# every turn, instead of that context silently disappearing once a WhatsApp
# thread runs long.
class Captain::Llm::ConversationSummarizerService < Captain::BaseTaskService
  pattr_initialize [:account!, :conversation_display_id!, :messages!]

  def perform
    text = format_messages
    return { message: nil } if text.blank?

    make_api_call(
      model: resolved_generator_model,
      messages: [
        { role: 'system', content: prompt_from_file('conversation_context_summary') },
        { role: 'user', content: text }
      ]
    )
  end

  private

  def event_name
    'utility'
  end

  def build_follow_up_context?
    false
  end

  # A background compaction pass, not a customer-facing reply — must not
  # consume a separate Captain response credit.
  def counts_toward_usage?
    false
  end

  def format_messages
    messages.filter_map { |message| format_message(message) }.join("\n")
  end

  def format_message(message)
    content = message.content_for_llm
    return nil if content.blank?

    "#{speaker_for(message)}: #{content}"
  end

  def speaker_for(message)
    return 'Customer' if message.incoming?
    return 'Assistant' if message.sender_type == 'Captain::Assistant'

    'Agent'
  end
end
