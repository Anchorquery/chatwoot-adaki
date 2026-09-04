module Enterprise::Conversation
  attr_accessor :captain_activity_reason, :captain_activity_reason_type

  # Written by #bot_handoff! below, read by Captain::HumanTakeoverEvaluator.
  CAPTAIN_HANDOFF_AT_KEY = 'captain_handoff_at'.freeze

  # Adaki lets Captain answer `open` conversations too (see
  # Captain::HumanTakeoverEvaluator), so the FOSS bot_handoff! — which only
  # flips pending → open — is a no-op for a conversation that is already
  # open: no status change, so AutoAssignmentHandler never runs, nobody gets
  # assigned, and nothing tells the evaluator that the bot stepped aside; the
  # very next customer message brings the bot straight back (production,
  # conversation 120, 2026-09-04). Two things make the handoff real
  # regardless of the starting status:
  #   1. a captain_handoff_at marker in additional_attributes that the
  #      evaluator honours until a human replies or the conversation is
  #      resolved (a later reopen starts fresh);
  #   2. the same inbox auto-assignment the pending → open transition would
  #      have triggered, when the conversation was already open.
  def bot_handoff!
    already_open = open?
    self.additional_attributes = (additional_attributes || {}).merge(CAPTAIN_HANDOFF_AT_KEY => Time.current.iso8601)
    super
    save! if changed?
    run_handoff_auto_assignment if already_open
  end

  def captain_handoff_at
    raw = additional_attributes&.dig(CAPTAIN_HANDOFF_AT_KEY)
    return nil unless raw.is_a?(String) && raw.present?

    Time.zone.parse(raw)
  rescue ArgumentError
    nil
  end

  def dispatch_captain_inference_resolved_event
    dispatch_captain_inference_event(Events::Types::CONVERSATION_CAPTAIN_INFERENCE_RESOLVED)
  end

  def dispatch_captain_inference_handoff_event
    dispatch_captain_inference_event(Events::Types::CONVERSATION_CAPTAIN_INFERENCE_HANDOFF)
  end

  def list_of_keys
    super + %w[sla_policy_id]
  end

  # Surface call lifecycle changes to the FE: writes to additional_attributes
  # call_status/call_direction should rebroadcast conversation_updated.
  def allowed_keys?
    super || call_attributes_changed?
  end

  def with_captain_activity_context(reason:, reason_type:)
    previous_reason = captain_activity_reason
    previous_reason_type = captain_activity_reason_type

    self.captain_activity_reason = reason
    self.captain_activity_reason_type = reason_type
    yield
  ensure
    self.captain_activity_reason = previous_reason
    self.captain_activity_reason_type = previous_reason_type
  end

  private

  # Mirrors AutoAssignmentHandler#run_auto_assignment, which is gated on a
  # status change to open and therefore never fires for a conversation that
  # was already open when Captain handed it off.
  def run_handoff_auto_assignment
    return unless inbox.enable_auto_assignment?
    return if assignee_id.present? && inbox.members.include?(assignee)

    if inbox.auto_assignment_v2_enabled?
      AutoAssignment::AssignmentJob.enqueue_for_inbox(inbox.id)
    else
      allowed_agent_ids = team_id.present? ? team_member_ids_with_capacity : inbox.member_ids_with_assignment_capacity
      AutoAssignment::AgentAssignmentService.new(conversation: self, allowed_agent_ids: allowed_agent_ids).perform
    end
  end

  def dispatch_captain_inference_event(event_name)
    dispatcher_dispatch(event_name)
  end

  def call_attributes_changed?
    return false if previous_changes['additional_attributes'].blank?

    # Compare before/after values for call keys — checking key presence alone
    # rebroadcasts on any unrelated additional_attributes write once the keys exist.
    before, after = previous_changes['additional_attributes']
    %w[call_status call_direction].any? { |key| (before || {})[key] != (after || {})[key] }
  end
end
