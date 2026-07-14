# == Schema Information
#
# Table name: captain_inbox_audiences
#
#  id                   :bigint           not null, primary key
#  channel_jids         :jsonb            not null
#  group_jids           :jsonb            not null
#  label_titles         :jsonb            not null
#  created_at           :datetime         not null
#  updated_at           :datetime         not null
#  captain_assistant_id :bigint           not null
#  inbox_id             :bigint           not null
#
# Indexes
#
#  index_captain_inbox_audiences_on_captain_assistant_id  (captain_assistant_id)
#  index_captain_inbox_audiences_on_inbox_id              (inbox_id)
#
class CaptainInboxAudience < ApplicationRecord
  belongs_to :inbox
  belongs_to :captain_assistant, class_name: 'Captain::Assistant'

  validate :group_jids_or_label_titles_present

  before_validation :normalize_filters

  scope :ordered, -> { order(:id) }

  def matches?(conversation)
    matches_group_jid?(conversation) || matches_channel_jid?(conversation) || matches_labels?(conversation)
  end

  private

  def matches_group_jid?(conversation)
    return false if group_jids.blank?

    jid = conversation.group_jid
    jid.present? && group_jids.include?(jid)
  end

  def matches_channel_jid?(conversation)
    return false if channel_jids.blank?

    jid = conversation.whatsapp_channel_jid
    jid.present? && channel_jids.include?(jid)
  end

  def matches_labels?(conversation)
    return false if label_titles.blank?

    conversation.label_list.intersect?(label_titles)
  end

  def normalize_filters
    self.group_jids = Array(group_jids).map { |jid| Conversation.normalize_whatsapp_jid(jid) }.compact_blank.uniq
    self.channel_jids = Array(channel_jids).map { |jid| Conversation.normalize_whatsapp_jid(jid) }.compact_blank.uniq
    self.label_titles = Array(label_titles).map { |title| title.to_s.strip.downcase }.compact_blank.uniq
  end

  def group_jids_or_label_titles_present
    return if group_jids.present? || channel_jids.present? || label_titles.present?

    errors.add(:base, 'must define at least one group_jid, channel_jid or label_title')
  end
end
