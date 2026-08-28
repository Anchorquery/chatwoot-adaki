# Leaves a private note on a conversation when a Captain handoff was actually
# caused by a diagnosable infrastructure failure (a dead/expired provider
# credential, an exhausted billing quota, Adaki's own monthly cap — see
# Captain::FailurePolicy) rather than the assistant's own decision to escalate.
#
# Both produce the exact same customer-facing handoff message, which is what
# made a bad API key look identical to a legitimate escalation in production
# (see docs/adaki/captain-remediacion.md §2a) — this is the fix: whoever opens
# the conversation next sees the real cause, independent of whether the
# handoff itself actually fires (the conversation may already be `open`, in
# which case nothing else records that anything went wrong at all).
class Captain::Conversation::FailureNotifier
  DIAGNOSABLE_FAILURE_CLASSES = %w[configuration limit_adaki].freeze

  def initialize(conversation:, assistant:, response:)
    @conversation = conversation
    @assistant = assistant
    @response = response || {}
  end

  def call
    return unless diagnosable?

    @conversation.messages.create!(
      message_type: :outgoing,
      private: true,
      sender: @assistant,
      account_id: @conversation.account_id,
      inbox_id: @conversation.inbox_id,
      content: note_content
    )
  rescue StandardError => e
    Rails.logger.error("[CAPTAIN][FailureNotifier] Could not record infrastructure error note: #{e.message}")
  end

  private

  def diagnosable?
    DIAGNOSABLE_FAILURE_CLASSES.include?(@response['failure_class'])
  end

  # `error` (the human-readable message) is preferred over `action_reason`
  # (a machine-oriented code like "ruby_llm_unauthorized_error") when both are
  # present — it reads far better in a note meant for a person to act on.
  def note_content
    "[Captain] Handoff automático (#{@response['failure_class']}), no por decisión del asistente: " \
      "#{@response['error'] || @response['action_reason']}"
  end
end
