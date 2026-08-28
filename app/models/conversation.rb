# == Schema Information
#
# Table name: conversations
#
#  id                     :integer          not null, primary key
#  additional_attributes  :jsonb
#  agent_last_seen_at     :datetime
#  assignee_last_seen_at  :datetime
#  cached_label_list      :text
#  contact_last_seen_at   :datetime
#  custom_attributes      :jsonb
#  first_reply_created_at :datetime
#  identifier             :string
#  last_activity_at       :datetime         not null
#  priority               :integer
#  snoozed_until          :datetime
#  status                 :integer          default("open"), not null
#  uuid                   :uuid             not null
#  waiting_since          :datetime
#  created_at             :datetime         not null
#  updated_at             :datetime         not null
#  account_id             :integer          not null
#  assignee_agent_bot_id  :bigint
#  assignee_id            :integer
#  campaign_id            :bigint
#  contact_id             :bigint
#  contact_inbox_id       :bigint
#  display_id             :integer          not null
#  inbox_id               :integer          not null
#  sla_policy_id          :bigint
#  team_id                :bigint
#
# Indexes
#
#  conv_acid_inbid_stat_asgnid_idx                    (account_id,inbox_id,status,assignee_id)
#  index_conversations_on_account_id                  (account_id)
#  index_conversations_on_account_id_and_display_id   (account_id,display_id) UNIQUE
#  index_conversations_on_assignee_id_and_account_id  (assignee_id,account_id)
#  index_conversations_on_campaign_id                 (campaign_id)
#  index_conversations_on_contact_id                  (contact_id)
#  index_conversations_on_contact_inbox_id            (contact_inbox_id)
#  index_conversations_on_first_reply_created_at      (first_reply_created_at)
#  index_conversations_on_id_and_account_id           (account_id,id)
#  index_conversations_on_identifier_and_account_id   (identifier,account_id)
#  index_conversations_on_inbox_id                    (inbox_id)
#  index_conversations_on_priority                    (priority)
#  index_conversations_on_status_and_account_id       (status,account_id)
#  index_conversations_on_status_and_priority         (status,priority)
#  index_conversations_on_team_id                     (team_id)
#  index_conversations_on_uuid                        (uuid) UNIQUE
#  index_conversations_on_waiting_since               (waiting_since)
#

class Conversation < ApplicationRecord
  include Labelable
  include LlmFormattable
  include AssignmentHandler
  include AutoAssignmentHandler
  include ActivityMessageHandler
  include UrlHelper
  include SortHandler
  include PushDataHelper
  include ConversationMuteHelpers

  validates :account_id, presence: true
  validates :inbox_id, presence: true
  validates :contact_id, presence: true
  before_validation :validate_additional_attributes
  before_validation :reset_agent_bot_when_assignee_present
  validates :additional_attributes, jsonb_attributes_length: true
  validates :custom_attributes, jsonb_attributes_length: true
  validates :uuid, uniqueness: true
  validate :validate_referer_url

  enum status: { open: 0, resolved: 1, pending: 2, snoozed: 3 }
  enum priority: { low: 0, medium: 1, high: 2, urgent: 3 }

  scope :unassigned, -> { where(assignee_id: nil) }
  scope :assigned, -> { where.not(assignee_id: nil) }
  scope :assigned_to, ->(agent) { where(assignee_id: agent.id) }
  scope :unattended, -> { where(first_reply_created_at: nil).or(where.not(waiting_since: nil)) }
  scope :resolvable_not_waiting, lambda { |auto_resolve_after|
    return none if auto_resolve_after.to_i.zero?

    open.where('last_activity_at < ? AND waiting_since IS NULL', Time.now.utc - auto_resolve_after.minutes)
  }
  scope :resolvable_all, lambda { |auto_resolve_after|
    return none if auto_resolve_after.to_i.zero?

    open.where('last_activity_at < ?', Time.now.utc - auto_resolve_after.minutes)
  }

  scope :last_user_message_at, lambda {
    joins(
      "INNER JOIN (#{last_messaged_conversations.to_sql}) AS grouped_conversations
      ON grouped_conversations.conversation_id = conversations.id"
    ).sort_on_last_user_message_at
  }

  belongs_to :account
  belongs_to :inbox
  belongs_to :assignee, class_name: 'User', optional: true, inverse_of: :assigned_conversations
  belongs_to :assignee_agent_bot, class_name: 'AgentBot', optional: true
  belongs_to :contact
  belongs_to :contact_inbox
  belongs_to :team, optional: true
  belongs_to :campaign, optional: true

  has_many :mentions, dependent: :destroy_async
  has_many :messages, dependent: :destroy_async, autosave: true
  has_one :csat_survey_response, dependent: :destroy_async
  has_many :conversation_participants, dependent: :destroy_async
  has_many :notifications, as: :primary_actor, dependent: :destroy_async
  has_many :attachments, through: :messages
  has_many :reporting_events, dependent: :destroy_async

  before_save :ensure_snooze_until_reset
  before_create :determine_conversation_status
  before_create :ensure_waiting_since

  after_update_commit :execute_after_update_commit_callbacks
  after_create_commit :notify_conversation_creation
  after_create_commit :load_attributes_created_by_db_triggers
  before_destroy :set_unread_count_deletion_data
  after_destroy_commit :notify_conversation_deletion

  delegate :auto_resolve_after, to: :account

  def can_reply?
    Conversations::MessageWindowService.new(self).can_reply?
  end

  def language
    additional_attributes&.dig('conversation_language')
  end

  # Be aware: The precision of created_at and last_activity_at may differ from Ruby's Time precision.
  # Our DB column (see schema) stores timestamps with second-level precision (no microseconds), so
  # if you assign a Ruby Time with microseconds, the DB will truncate it. This may cause subtle differences
  # if you compare or copy these values in Ruby, also in our specs
  # So in specs rely on to be_with(1.second) instead of to eq()
  # TODO: Migrate to use a timestamp with microsecond precision
  def last_activity_at
    self[:last_activity_at] || created_at
  end

  def last_incoming_message
    messages.where(account_id: account_id)&.incoming&.last
  end

  def toggle_status
    # FIXME: implement state machine with aasm
    self.status = open? ? :resolved : :open
    self.status = :open if pending? || snoozed?
    save
  end

  def toggle_priority(priority = nil)
    self.priority = priority.presence
    save
  end

  def bot_handoff!
    update(waiting_since: Time.current) if waiting_since.blank?
    open!
    dispatcher_dispatch(CONVERSATION_BOT_HANDOFF)
  end

  def unread_messages
    agent_last_seen_at.present? ? messages.created_since(agent_last_seen_at) : messages
  end

  def assignee_unread_messages
    assignee_last_seen_at.present? ? messages.created_since(assignee_last_seen_at) : messages
  end

  def unread_incoming_messages
    unread_messages.where(account_id: account_id).incoming.last(10)
  end

  def cached_label_list_array
    (cached_label_list || '').split(',').map(&:strip)
  end

  def notifiable_assignee_change?
    return false unless saved_change_to_assignee_id?
    return false if assignee_id.blank?
    return false if self_assign?(assignee_id)

    true
  end

  # Virtual attribute till we switch completely to polymorphic assignee
  def assignee_type
    return 'AgentBot' if assignee_agent_bot_id.present?
    return 'User' if assignee_id.present?

    nil
  end

  def assigned_entity
    assignee_agent_bot || assignee
  end

  def tweet?
    inbox.inbox_type == 'Twitter' && additional_attributes['type'] == 'tweet'
  end

  def group?
    # WhatsApp group JIDs always contain "@g.us" (e.g. 1203630...@g.us). API-channel
    # bridges (Evolution and similar) may stash this JID in the contact_inbox source_id,
    # the contact identifier/phone, or anywhere inside the conversation/contact
    # additional_attributes, so we scan all of them. "@g.us" (with the "@") is used to
    # avoid false positives with domains such as "img.us".
    return true if group_jid.present?

    # Explicit group markers set by Telegram, Evolution and other integrations, on either
    # the conversation or the contact (snake_case and camelCase variants). These don't carry
    # a clean, reusable JID (see #group_jid), only a boolean signal that this is a group.
    return true if chat_attributes.any? { |attrs| %w[chat_type type].any? { |k| attrs[k].to_s.downcase.include?('group') } }
    return true if chat_attributes.any? { |attrs| %w[group_id groupId].any? { |k| attrs[k].present? } }
    return true if chat_attributes.any? { |attrs| %w[is_group isGroup].any? { |k| ActiveModel::Type::Boolean.new.cast(attrs[k]) } }

    false
  end

  # The normalized WhatsApp group id for this conversation (e.g. "1203630..." or
  # "12345-67890"), or nil if this isn't a recognizable WhatsApp group conversation.
  # Used to match a conversation against a Captain audience's configured group_jids.
  # Deliberately not memoized: contact_inbox/additional_attributes can be mutated on this
  # same in-memory instance after the first call (e.g. a bridge backfills the JID after the
  # conversation object was already built), and the underlying scan is cheap enough that
  # caching isn't worth risking a stale answer for the rest of the object's lifetime.
  def group_jid
    matched_group_jid || matched_structured_group_id
  end

  def self.normalize_group_jid(raw)
    normalize_whatsapp_jid(raw)
  end

  # Generic "strip everything after @" normalizer, shared by every WhatsApp JID kind
  # (group "@g.us", channel/newsletter "@newsletter", ...).
  def self.normalize_whatsapp_jid(raw)
    raw.to_s.split('@').first.presence
  end

  # WhatsApp Channels (the one-to-many broadcast feature, shown as "Canales" in the app)
  # use JIDs suffixed "@newsletter" — that's the protocol name WhatsApp/Baileys still use
  # internally for what the UI calls a Channel. Detected the same way as #group?: scan
  # every place a bridge (Evolution and similar) might have stashed the JID.
  def whatsapp_channel?
    return true if whatsapp_channel_jid.present?

    chat_attributes.any? { |attrs| %w[chat_type type].any? { |k| attrs[k].to_s.downcase.include?('newsletter') } }
  end

  # The normalized WhatsApp channel (newsletter) id for this conversation, or nil if this
  # isn't a recognizable WhatsApp channel conversation. Used to match a conversation against
  # a Captain audience's configured channel_jids. Unlike #group_jid, there is no structural
  # fallback: channel and group ids are both long digit strings once the "@..." suffix is
  # stripped, so without the marker they can't be told apart.
  # Not memoized — see the comment on #group_jid above.
  def whatsapp_channel_jid
    matched_jid_for_marker(WHATSAPP_NEWSLETTER_JID_MARKER)
  end

  # The Captain assistant that should handle this conversation: the first
  # CaptainInboxAudience whose group_jids/label_titles match it, or the inbox's
  # default assistant (captain_inboxes) if no audience matches. Either side of
  # that fallback can be absent, in which case this returns nil (no Captain
  # responds — handled manually).
  def resolved_captain_assistant
    return @resolved_captain_assistant if defined?(@resolved_captain_assistant)

    @resolved_captain_assistant = matching_captain_audience&.captain_assistant || inbox_captain_assistant
  end

  def resolved_captain_active?
    assistant = resolved_captain_assistant
    assistant.present? && assistant.autopilot_enabled? &&
      inbox.respond_to?(:captain_responses_available?) && inbox.captain_responses_available?
  end

  # Default phone numbers used by channel providers (Evolution/WhatsApp bridges)
  # as the "service contact" through which they publish instance-status
  # notifications (QR codes, connection events, import progress) as if they
  # were incoming messages. Lives in FOSS (not CaptainInbox, which is
  # enterprise-only and stripped from `run_foss_spec.yml`) so this constant
  # stays resolvable even when enterprise/ isn't loaded.
  DEFAULT_SERVICE_CONTACT_NUMBERS = ['+123456'].freeze

  # See Contact#service_channel_contact?. Captain must never engage with this
  # conversation: no response, no handoff, no auto-resolution — it is not a
  # customer conversation.
  def service_channel_conversation?
    contact.present? && contact.service_channel_contact?(service_contact_numbers)
  end

  # Generic commands that always summon the bot, regardless of its name.
  GROUP_BOT_COMMANDS = ['!bot', '/bot', '/ask'].freeze

  def bot_mentioned?(message_content)
    return false if message_content.blank?

    content = message_content.strip
    downcased = content.downcase

    return true if GROUP_BOT_COMMANDS.any? { |command| downcased.start_with?(command) }

    bot_trigger_aliases.any? { |alias_token| bot_alias_mentioned?(content, alias_token) }
  end

  def recent_messages
    messages.chat.last(5)
  end

  def csat_survey_link
    "#{ENV.fetch('FRONTEND_URL', nil)}/survey/responses/#{uuid}"
  end

  def dispatch_conversation_updated_event(previous_changes = nil)
    dispatcher_dispatch(CONVERSATION_UPDATED, previous_changes)
  end

  private

  def matching_captain_audience
    return nil unless inbox.respond_to?(:captain_inbox_audiences)

    inbox.captain_inbox_audiences.ordered.detect { |audience| audience.matches?(self) }
  end

  def service_contact_numbers
    return DEFAULT_SERVICE_CONTACT_NUMBERS unless inbox.respond_to?(:captain_inbox)

    inbox.captain_inbox&.service_contact_numbers_value || DEFAULT_SERVICE_CONTACT_NUMBERS
  end

  def inbox_captain_assistant
    inbox.respond_to?(:captain_assistant) ? inbox.captain_assistant : nil
  end

  WHATSAPP_GROUP_JID_MARKER = '@g.us'.freeze
  WHATSAPP_NEWSLETTER_JID_MARKER = '@newsletter'.freeze

  def matched_group_jid
    matched_jid_for_marker(WHATSAPP_GROUP_JID_MARKER)
  end

  # Finds the first JID candidate containing the given "@..." marker and normalizes it.
  # Shared by every WhatsApp JID kind (group, channel/newsletter, ...).
  def matched_jid_for_marker(marker)
    raw = jid_candidates.find { |value| value.to_s.include?(marker) }
    self.class.normalize_whatsapp_jid(raw)
  end

  def jid_candidates
    [
      contact_inbox&.source_id,
      contact&.identifier,
      contact&.phone_number,
      *flatten_attribute_values(additional_attributes),
      *flatten_attribute_values(contact&.additional_attributes)
    ]
  end

  def flatten_attribute_values(attributes)
    return [] unless attributes.is_a?(Hash)

    attributes.values.flat_map do |value|
      case value
      when Hash then flatten_attribute_values(value)
      when Array then value.map(&:to_s)
      else value.to_s
      end
    end
  end

  def chat_attributes
    [additional_attributes, contact&.additional_attributes].select { |attrs| attrs.is_a?(Hash) }
  end

  # Recognizes a WhatsApp group id even when the "@g.us" suffix was stripped by the bridge.
  # Group ids are structurally distinct from individual phone numbers:
  #   - legacy groups look like "<digits>-<digits>" (e.g. 12345-67890); phone numbers never
  #     contain a hyphen,
  #   - modern groups are ~18-digit numbers, well beyond the 15-digit E.164 phone maximum.
  def matched_structured_group_id
    raw = [contact_inbox&.source_id, contact&.identifier].find { |value| structured_group_identifier?(value) }
    self.class.normalize_group_jid(raw)
  end

  def structured_group_identifier?(raw)
    full = raw.to_s
    local_part, separator, = full.partition('@')
    return false if local_part.blank?
    # Only guess by shape when there's no "@" at all (fully stripped by the bridge). Any "@"
    # — even a malformed one with an empty domain — means this JID already carries a marker
    # of its own kind (e.g. "@newsletter", "@lid") that we shouldn't override by guessing
    # "group" from digit-count alone.
    return false if separator.present?
    # WhatsApp JIDs are 100% numeric (modern) or "<digits>-<digits>" (legacy). Anything
    # with letters (UUIDs from API channel source_ids, slugs, etc.) is NOT a group id.
    return false if local_part.match?(/[a-z]/i)
    return true if local_part.match?(/\A\+?\d{3,}-\d{3,}\z/)

    local_part.gsub(/\D/, '').length > 15
  end

  # Tokens that summon the bot in a group when written as "@token" or "/token".
  # Built from, in priority order:
  #   - the explicitly configured short alias (config.group_trigger),
  #   - the first word of the bot's name (so long names are still reachable),
  #   - the bot's WhatsApp number. A native WhatsApp @mention is delivered in the
  #     message text as "@<number>" (the digits, no "+"), so registering the number
  #     makes native mentions work through the very same text path.
  def bot_trigger_aliases
    aliases = []

    if resolved_captain_assistant.present?
      assistant = resolved_captain_assistant
      aliases << assistant.config['group_trigger'] if assistant.config.is_a?(Hash)
      aliases << assistant.name
    end

    aliases << inbox.agent_bot.name if inbox.agent_bot.present?

    tokens = aliases.filter_map { |value| value.to_s.strip.split.first&.downcase }
    tokens << bot_whatsapp_number
    tokens.compact_blank.uniq
  end

  # Digits-only WhatsApp number of the bot, used to detect native WhatsApp mentions.
  # A native WhatsApp @mention embeds the mentioned party's number in the message text
  # as "@<digits>". The bot's own number lives on the WhatsApp channel, so we fall back
  # to it when no number was set manually — this makes native mentions work with zero config.
  def bot_whatsapp_number
    configured_bot_whatsapp_number || channel_whatsapp_number
  end

  def configured_bot_whatsapp_number
    return if resolved_captain_assistant.blank?

    config = resolved_captain_assistant.config
    return unless config.is_a?(Hash)

    config['whatsapp_number'].to_s.gsub(/\D/, '').presence
  end

  def channel_whatsapp_number
    channel = inbox&.channel
    return unless channel.respond_to?(:phone_number)

    channel.phone_number.to_s.gsub(/\D/, '').presence
  end

  def bot_alias_mentioned?(content, alias_token)
    return false if alias_token.blank?

    # Match "@token" or "/token" as a whole token, anywhere in the message, case-insensitive.
    pattern = %r{(?:\A|\s|[[:punct:]])[@/]#{Regexp.escape(alias_token)}(?![[:alnum:]])}i
    content.match?(pattern)
  end

  def execute_after_update_commit_callbacks
    handle_resolved_status_change
    notify_status_change
    create_activity
    notify_conversation_updation
  end

  def handle_resolved_status_change
    # When conversation is resolved, clear waiting_since using update_column to avoid callbacks
    return unless saved_change_to_status? && status == 'resolved'

    # rubocop:disable Rails/SkipsModelValidations
    update_column(:waiting_since, nil)
    # rubocop:enable Rails/SkipsModelValidations
  end

  def ensure_snooze_until_reset
    self.snoozed_until = nil unless snoozed?
  end

  def ensure_waiting_since
    self.waiting_since = created_at
  end

  def validate_additional_attributes
    self.additional_attributes = {} unless additional_attributes.is_a?(Hash)
  end

  def reset_agent_bot_when_assignee_present
    return if assignee_id.blank?

    self.assignee_agent_bot_id = nil
  end

  def determine_conversation_status
    self.status = :resolved and return if contact.blocked?

    return handle_campaign_status if campaign.present?

    # TODO: make this an inbox config instead of assuming bot conversations should start as pending
    self.status = :pending if inbox.active_bot?
  end

  def handle_campaign_status
    # If campaign has no sender (bot-initiated) and inbox has active bot, let bot handle it
    self.status = :pending if campaign.sender_id.nil? && inbox.active_bot?
  end

  def notify_conversation_creation
    dispatcher_dispatch(CONVERSATION_CREATED)
  end

  def notify_conversation_deletion
    return if @unread_count_deletion_data.blank?

    Rails.configuration.dispatcher.dispatch(CONVERSATION_DELETED, Time.zone.now, conversation_data: @unread_count_deletion_data)
  end

  def notify_conversation_updation
    return unless previous_changes.keys.present? && allowed_keys?

    dispatch_conversation_updated_event(previous_changes)
  end

  def list_of_keys
    %w[team_id assignee_id assignee_agent_bot_id status snoozed_until custom_attributes label_list waiting_since
       first_reply_created_at priority]
  end

  def allowed_keys?
    (
      previous_changes.keys.intersect?(list_of_keys) ||
      (previous_changes['additional_attributes'].present? && previous_changes['additional_attributes'][1].keys.intersect?(%w[conversation_language]))
    )
  end

  def load_attributes_created_by_db_triggers
    # Display id is set via a trigger in the database
    # So we need to specifically fetch it after the record is created
    # We can't use reload because it will clear the previous changes, which we need for the dispatcher
    obj_from_db = self.class.find(id)
    self[:display_id] = obj_from_db[:display_id]
    self[:uuid] = obj_from_db[:uuid]
  end

  def notify_status_change
    {
      CONVERSATION_OPENED => -> { saved_change_to_status? && open? },
      CONVERSATION_RESOLVED => -> { saved_change_to_status? && resolved? },
      CONVERSATION_STATUS_CHANGED => -> { saved_change_to_status? },
      CONVERSATION_READ => -> { saved_change_to_contact_last_seen_at? },
      CONVERSATION_CONTACT_CHANGED => -> { saved_change_to_contact_id? }
    }.each do |event, condition|
      condition.call && dispatcher_dispatch(event, status_change)
    end
  end

  def dispatcher_dispatch(event_name, changed_attributes = nil)
    Rails.configuration.dispatcher.dispatch(event_name, Time.zone.now, conversation: self, notifiable_assignee_change: notifiable_assignee_change?,
                                                                       changed_attributes: changed_attributes,
                                                                       performed_by: Current.executed_by)
  end

  def set_unread_count_deletion_data
    @unread_count_deletion_data = {
      id: id,
      account_id: account_id,
      inbox_id: inbox_id,
      assignee_id: assignee_id,
      team_id: team_id,
      cached_label_list: cached_label_list
    }
  end

  def conversation_status_changed_to_open?
    return false unless open?
    # saved_change_to_status? method only works in case of update
    return true if previous_changes.key?(:id) || saved_change_to_status?
  end

  def create_label_change(user_name)
    return unless user_name

    previous_labels, current_labels = previous_changes[:label_list]
    return unless (previous_labels.is_a? Array) && (current_labels.is_a? Array)

    create_label_added(user_name, current_labels - previous_labels)
    create_label_removed(user_name, previous_labels - current_labels)
  end

  def validate_referer_url
    return unless additional_attributes['referer']

    self['additional_attributes']['referer'] = nil unless url_valid?(additional_attributes['referer'])
  end

  # creating db triggers
  trigger.before(:insert).for_each(:row) do
    "NEW.display_id := nextval('conv_dpid_seq_' || NEW.account_id);"
  end
end

Conversation.include_mod_with('Audit::Conversation')
Conversation.include_mod_with('Concerns::Conversation')
Conversation.prepend_mod_with('Conversation')
