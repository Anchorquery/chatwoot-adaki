# Runs a short grace period after Captain hands a conversation off to a
# human (Enterprise::Conversation#bot_handoff!). If by then nobody owns the
# conversation — no assignee (auto-assignment only picks agents who are
# online with free capacity) and no human reply — it raises the alarm to the
# whole handoff team, or to every inbox collaborator when no team is
# configured:
#
#   1. a private note that @mentions the team (or each collaborator), which
#      puts the conversation in everyone's "Mentions" folder, adds them as
#      participants and fires the in-app mention notification;
#   2. a direct email to each of them, independent of their personal
#      notification settings — by default agents only get the "assigned to
#      you" email, so an unassigned handoff would otherwise be silent.
#
# Idempotent per handoff: the check is skipped when someone took the
# conversation meanwhile, when a newer handoff superseded this one, or when
# this handoff was already announced.
class Captain::Conversation::UnattendedHandoffJob < ApplicationJob
  queue_as :default

  NOTIFIED_AT_KEY = 'captain_unattended_notified_at'.freeze

  def perform(conversation, handoff_at)
    @conversation = conversation
    @handoff_at = Time.zone.parse(handoff_at.to_s)
    return if @handoff_at.blank?
    return unless still_unattended?

    recipients = recipient_users
    if recipients.empty?
      Rails.logger.warn("[CAPTAIN][UnattendedHandoff] conversation=#{conversation.display_id} has nobody to notify")
      return
    end

    mark_notified!
    post_mention_note
    deliver_emails(recipients)
    Rails.logger.info(
      "[CAPTAIN][UnattendedHandoff] conversation=#{conversation.display_id} notified=#{recipients.size} " \
      "team=#{handoff_team&.id.inspect}"
    )
  end

  private

  attr_reader :conversation, :handoff_at

  def still_unattended?
    return false unless conversation.open?
    return false if conversation.assignee_id.present?
    return false unless same_handoff?
    return false if already_notified?

    !human_replied_since_handoff?
  end

  # A later handoff enqueues its own check; a stale job must not announce it.
  def same_handoff?
    current = conversation.captain_handoff_at
    current.present? && current.to_i == handoff_at.to_i
  end

  def already_notified?
    raw = conversation.additional_attributes&.dig(NOTIFIED_AT_KEY)
    return false if raw.blank?

    Time.zone.parse(raw.to_s).to_i >= handoff_at.to_i
  rescue ArgumentError
    false
  end

  def human_replied_since_handoff?
    conversation.messages.outgoing
                .where(private: false, sender_type: 'User')
                .exists?(['created_at > ?', handoff_at])
  end

  def mark_notified!
    conversation.update!(
      additional_attributes: (conversation.additional_attributes || {}).merge(NOTIFIED_AT_KEY => Time.current.iso8601)
    )
  end

  # Team first (the conversation's own team, or the Captain handoff team
  # configured for the inbox), otherwise every collaborator of the inbox.
  def handoff_team
    return @handoff_team if defined?(@handoff_team)

    inbox = conversation.inbox
    configured = inbox.respond_to?(:captain_inbox) ? inbox.captain_inbox&.handoff_team : nil
    @handoff_team = conversation.team || configured
  end

  def recipient_users
    scope = handoff_team ? handoff_team.members : conversation.inbox.members
    scope.to_a.uniq
  end

  def assistant
    @assistant ||= if conversation.respond_to?(:resolved_captain_assistant)
                     conversation.resolved_captain_assistant
                   else
                     conversation.inbox.captain_inbox&.captain_assistant
                   end
  end

  def post_mention_note
    return if assistant.blank?

    I18n.with_locale(conversation.account.locale) do
      conversation.messages.create!(
        message_type: :outgoing,
        private: true,
        sender: assistant,
        account_id: conversation.account_id,
        inbox_id: conversation.inbox_id,
        content: I18n.t('conversations.captain.unattended_handoff_note', mentions: mention_markup)
      )
    end
  end

  def mention_markup
    return mention_link('team', handoff_team.id, handoff_team.name) if handoff_team

    recipient_users.map { |user| mention_link('user', user.id, user.available_name) }.join(' ')
  end

  def mention_link(kind, id, name)
    "[@#{name}](mention://#{kind}/#{id}/#{ERB::Util.url_encode(name.to_s)})"
  end

  # Direct emails, on purpose outside the per-user notification settings: an
  # unassigned handoff has no assignee to email, and the mention email is off
  # by default for every agent. Same guards as Notification::EmailNotificationService.
  def deliver_emails(recipients)
    account = conversation.account
    recipients.each do |user|
      next if user.email.blank? || user.confirmed_at.nil?
      next unless account.within_email_rate_limit?

      AgentNotifications::ConversationNotificationsMailer
        .with(account: account)
        .captain_unattended_handoff(conversation, user, nil)
        .deliver_later
      account.increment_email_sent_count
    end
  end
end
