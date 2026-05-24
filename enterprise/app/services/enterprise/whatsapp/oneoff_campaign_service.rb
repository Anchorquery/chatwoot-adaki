module Enterprise::Whatsapp::OneoffCampaignService
  def perform
    Adaki::CampaignApprovalService.new(campaign).ensure_approved!
    enforce_tier_safety!
    super
  end

  private

  def enforce_tier_safety!
    return unless channel.is_a?(Channel::Whatsapp)

    if channel.tier_locked?
      Adaki::AuditLogger.log(
        account: campaign.account,
        action: 'campaign.blocked.tier_locked',
        auditable: campaign,
        payload: { channel_id: channel.id, reason: channel.tier_lock_reason }
      )
      raise "Channel #{channel.id} is tier-locked (#{channel.tier_lock_reason}). Campaign blocked."
    end

    monitor = Adaki::TierMonitorService.new(channel)
    recipient_count = estimate_recipient_count
    return if monitor.safe_to_send?(recipient_count)

    Adaki::AuditLogger.log(
      account: campaign.account,
      action: 'campaign.blocked.tier_threshold',
      auditable: campaign,
      payload: { channel_id: channel.id, recipient_count: recipient_count }
    )
    raise "Channel #{channel.id} would exceed safe tier threshold (#{recipient_count} recipients). Campaign blocked."
  end

  def estimate_recipient_count
    audience = campaign.audience.to_a
    return campaign.account.contacts.count if audience.any? { |a| %w[All AllContacts].include?(a['type'].to_s) }

    contact_ids = audience.select { |a| %w[Contact ContactId].include?(a['type'].to_s) }.map { |a| a['id'] }
    label_ids = audience.select { |a| a['type'].to_s == 'Label' }.map { |a| a['id'] }

    count = 0
    count += campaign.account.contacts.where(id: contact_ids).count if contact_ids.any?
    if label_ids.any?
      labels = campaign.account.labels.where(id: label_ids).pluck(:title)
      count += campaign.account.contacts.tagged_with(labels, any: true).count if labels.any?
    end
    count
  end
end
