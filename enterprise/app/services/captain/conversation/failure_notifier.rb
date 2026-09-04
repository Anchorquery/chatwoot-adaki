# Leaves a private note on a conversation when a Captain handoff was actually
# caused by a failure (a dead/expired provider credential, an exhausted
# billing quota, Adaki's own monthly cap, a prompt that no longer fits, or an
# unexpected error in Captain's own code — see Captain::FailurePolicy) rather
# than the assistant's own decision to escalate.
#
# Both produce the exact same customer-facing handoff message, which is what
# made a bad API key look identical to a legitimate escalation in production
# (see docs/adaki/captain-remediacion.md §2a) — this is the fix: whoever opens
# the conversation next sees the real cause, independent of whether the
# handoff itself actually fires (the conversation may already be `open`, in
# which case nothing else records that anything went wrong at all).
#
# `unknown` is deliberately included: on 2026-09-04 a NameError in the model
# resolver turned every customer message on account 3 into an instant handoff
# and, being classified `unknown`, left no note anywhere an operator looks
# (§7.4). Only `transient` is excluded — it is retried by the job and never
# reaches this notifier.
class Captain::Conversation::FailureNotifier
  DIAGNOSABLE_FAILURE_CLASSES = %w[configuration limit_adaki budget unknown].freeze

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
    body = "[Captain] Handoff automático (#{@response['failure_class']}), no por decisión del asistente: " \
           "#{@response['error'] || @response['action_reason']}"
    mention = mention_markup
    mention ? "#{mention} #{body}" : body
  end

  # @mention (Chatwoot's private-note markup, picked up by
  # Messages::MentionService) so the person who should act gets a
  # conversation_mention notification that carries the real cause, instead
  # of a generic "assigned to you" indistinguishable from any other
  # conversation. Assignee first — bot_handoff! runs right before this and
  # assigns synchronously on the legacy assignment path; with assignment_v2
  # the assignment is a background job that hasn't run yet, so fall back to
  # the handoff team (already on the conversation, or configured for Captain
  # on this inbox). No mention at all when neither exists.
  def mention_markup
    assignee = @conversation.assignee
    return mention_link('user', assignee.id, assignee.name) if assignee

    team = @conversation.team || captain_handoff_team
    return nil unless team

    mention_link('team', team.id, team.name)
  end

  def mention_link(kind, id, name)
    "[@#{name}](mention://#{kind}/#{id}/#{ERB::Util.url_encode(name.to_s)})"
  end

  def captain_handoff_team
    inbox = @conversation.inbox
    inbox.respond_to?(:captain_inbox) ? inbox.captain_inbox&.handoff_team : nil
  end
end
