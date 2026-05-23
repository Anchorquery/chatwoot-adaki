class Adaki::WhatsappTierSnapshot < ApplicationRecord
  self.table_name = 'adaki_whatsapp_tier_snapshots'

  TIERS = {
    1 => { name: 'TIER_50',    daily: 50 },
    2 => { name: 'TIER_250',   daily: 250 },
    3 => { name: 'TIER_1K',    daily: 1_000 },
    4 => { name: 'TIER_10K',   daily: 10_000 },
    5 => { name: 'TIER_100K',  daily: 100_000 },
    6 => { name: 'UNLIMITED',  daily: Float::INFINITY }
  }.freeze

  belongs_to :channel_whatsapp, class_name: 'Channel::Whatsapp', foreign_key: :channel_whatsapp_id

  validates :captured_at, presence: true

  scope :latest_for, ->(channel) { where(channel_whatsapp_id: channel.id).order(captured_at: :desc) }

  def tier_label
    TIERS.dig(messaging_limit_tier, :name)
  end

  def usage_ratio
    return 0.0 if max_daily_conversations.to_i.zero?

    conversations_sent_24h.to_i.to_f / max_daily_conversations
  end
end
