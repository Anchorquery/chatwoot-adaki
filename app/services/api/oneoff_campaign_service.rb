class Api::OneoffCampaignService
  pattr_initialize [:campaign!]

  def perform
    validate_campaign!
    campaign.completed!
    process_audience(audience_labels)
  end

  private

  delegate :inbox, to: :campaign

  def validate_campaign_type!
    raise "Invalid campaign #{campaign.id}" unless campaign.inbox.inbox_type == 'API' && campaign.one_off?
  end

  def validate_campaign_configuration!
    return if inbox.channel.webhook_url.present?

    raise 'API inbox must have a webhook URL'
  end

  def validate_campaign_status!
    raise 'Completed Campaign' if campaign.completed?
  end

  def validate_campaign!
    validate_campaign_type!
    validate_campaign_configuration!
    validate_campaign_status!
  end

  def audience_labels
    audience_label_ids = campaign.audience.select { |audience| audience['type'] == 'Label' }.pluck('id')
    campaign.account.labels.where(id: audience_label_ids).pluck(:title)
  end

  def process_audience(audience_labels)
    campaign.account.contacts.tagged_with(audience_labels, any: true).each do |contact|
      contact_inbox = inbox.contact_inboxes.find_by(contact: contact)
      next unless contact_inbox

      content = Liquid::CampaignTemplateService.new(campaign: campaign, contact: contact).call(campaign.message)
      next if content.blank?

      ::Campaigns::CampaignConversationBuilder.new(
        contact_inbox_id: contact_inbox.id,
        campaign_display_id: campaign.display_id,
        message_content: content
      ).perform
    end
  end
end

Api::OneoffCampaignService.prepend_mod_with('Api::OneoffCampaignService')
