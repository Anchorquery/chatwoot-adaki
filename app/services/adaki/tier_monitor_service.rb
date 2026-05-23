class Adaki::TierMonitorService
  WARN_THRESHOLD = 0.75
  LOCK_THRESHOLD = 0.95

  def initialize(channel)
    @channel = channel
  end

  def perform
    payload = fetch_phone_number_metadata
    return if payload.blank?

    tier = parse_tier(payload['messaging_limit_tier'])
    quality = payload['quality_rating']
    sent_24h = payload['conversations_sent_24h'].to_i
    max_daily = Adaki::WhatsappTierSnapshot::TIERS.dig(tier, :daily)
    max_daily = nil if max_daily.is_a?(Float) && max_daily.infinite?

    snapshot = Adaki::WhatsappTierSnapshot.create!(
      channel_whatsapp_id: @channel.id,
      messaging_limit_tier: tier,
      max_daily_conversations: max_daily,
      conversations_sent_24h: sent_24h,
      quality_rating: quality,
      status: payload['status'],
      raw_payload: payload,
      captured_at: Time.current
    )

    @channel.update!(
      messaging_tier: tier,
      quality_rating: quality,
      daily_conversation_limit: max_daily,
      tier_checked_at: Time.current
    )

    enforce_lock_policy!(snapshot, quality)
    snapshot
  rescue StandardError => e
    Rails.logger.error "[AdakiTierMonitor] channel=#{@channel.id} error=#{e.class}: #{e.message}"
    nil
  end

  def safe_to_send?(estimated_recipients = 0)
    return false if @channel.tier_locked?

    refresh_if_stale!

    limit = @channel.reload.daily_conversation_limit
    return true if limit.blank?

    used = latest_snapshot&.conversations_sent_24h.to_i
    (used + estimated_recipients) <= (limit * LOCK_THRESHOLD)
  end

  def refresh_if_stale!
    return unless @channel.tier_checked_at.blank? || @channel.tier_checked_at < 1.hour.ago

    perform
    @latest_snapshot = nil
  end

  def latest_snapshot
    @latest_snapshot ||= Adaki::WhatsappTierSnapshot.latest_for(@channel).first
  end

  private

  def fetch_phone_number_metadata
    base = ENV.fetch('WHATSAPP_CLOUD_BASE_URL', 'https://graph.facebook.com')
    phone_id = @channel.provider_config['phone_number_id']
    api_key = @channel.provider_config['api_key']
    return {} if phone_id.blank? || api_key.blank?

    url = "#{base}/v19.0/#{phone_id}?fields=quality_rating,messaging_limit_tier,status,conversations_sent_24h"
    response = HTTParty.get(url, headers: { 'Authorization' => "Bearer #{api_key}" }, timeout: 10)
    return {} unless response.success?

    response.parsed_response.to_h
  end

  def parse_tier(value)
    case value.to_s
    when 'TIER_50' then 1
    when 'TIER_250' then 2
    when 'TIER_1K' then 3
    when 'TIER_10K' then 4
    when 'TIER_100K' then 5
    when 'UNLIMITED' then 6
    else value.to_i
    end
  end

  def enforce_lock_policy!(snapshot, quality)
    if quality.to_s.casecmp('red').zero?
      lock!('quality_rating_red')
      notify('quality_red')
      return
    end

    ratio = snapshot.usage_ratio
    if ratio >= LOCK_THRESHOLD
      lock!('daily_limit_near_exhaustion')
      notify('limit_lock')
    elsif ratio >= WARN_THRESHOLD
      notify('limit_warning')
    end
  end

  def lock!(reason)
    return if @channel.tier_locked? && @channel.tier_lock_reason == reason

    @channel.update!(tier_locked: true, tier_lock_reason: reason)
    Adaki::AuditLogger.log(
      account: @channel.account,
      action: 'whatsapp.tier.lock',
      payload: { channel_id: @channel.id, reason: reason }
    )
  end

  def notify(kind)
    Rails.logger.warn "[AdakiTierMonitor] notify=#{kind} channel=#{@channel.id}"
    return unless kind == 'quality_red'

    inbox = @channel.inbox
    return if inbox.blank?

    AdministratorNotifications::ChannelNotificationsMailer
      .with(account: @channel.account)
      .whatsapp_disconnect(inbox)
      &.deliver_later
  rescue StandardError => e
    Rails.logger.warn "[AdakiTierMonitor] notify_failed kind=#{kind} #{e.message}"
  end
end
