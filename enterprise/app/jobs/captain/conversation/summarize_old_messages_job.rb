# See docs/adaki/captain-plan-latencia-2026-09.md fase 5.3 and
# Captain::Conversation::HistoryBuilder#maybe_enqueue_summary!, which enqueues
# this the first time a conversation outgrows its history window, and again
# every SUMMARY_RESUMMARIZE_DELTA messages after that. Runs off the customer's
# critical path — the summary it writes is picked up on a LATER turn, not
# this one.
class Captain::Conversation::SummarizeOldMessagesJob < ApplicationJob
  queue_as :low

  def perform(conversation, old_count)
    old_messages = fetch_old_messages(conversation, old_count)
    return if old_messages.empty?

    result = Captain::Llm::ConversationSummarizerService.new(
      account: conversation.account,
      conversation_display_id: conversation.display_id,
      messages: old_messages
    ).perform
    return if result[:error].present? || result[:message].blank?

    conversation.update!(
      additional_attributes: conversation.additional_attributes.merge(
        'captain_summary' => result[:message],
        'captain_summary_covers' => old_count
      )
    )
  rescue StandardError => e
    Rails.logger.warn("[Captain] conversation summary skipped for conversation=#{conversation.display_id}: #{e.class}: #{e.message}")
  end

  private

  # Re-queried fresh here (rather than passed in) so the summary reflects
  # whatever is actually in the DB by the time this low-priority job runs,
  # not a snapshot from whenever it was enqueued.
  def fetch_old_messages(conversation, old_count)
    conversation.messages
                .where(message_type: [:incoming, :outgoing])
                .where(private: false)
                .reorder(created_at: :asc, id: :asc)
                .limit(old_count)
                .to_a
  end
end
