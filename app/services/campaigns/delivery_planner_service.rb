class Campaigns::DeliveryPlannerService
  pattr_initialize [:campaign!]

  def perform
    Rails.logger.info("[CampaignPlanner] perform START campaign=#{campaign.id} status=#{campaign.campaign_status}")
    return if campaign.completed?

    contacts = fetch_audience_contacts
    Rails.logger.info("[CampaignPlanner] audience for campaign=#{campaign.id} contacts=#{contacts.map(&:id)}")
    if contacts.empty?
      Rails.logger.warn("[CampaignPlanner] no contacts for campaign=#{campaign.id} — marking completed without sending")
      campaign.completed!
      return
    end

    # Inicializar estado operativo
    campaign.update!(
      campaign_status: :running,
      delivery_state: {
        total_contacts: contacts.size,
        contact_ids: contacts.map(&:id),
        processed_index: 0,
        sent_count: 0,
        failed_count: 0,
        consecutive_failures: 0,
        sent_today_count: 0,
        sent_window_count: 0,
        window_started_at: nil,
        last_sent_on: nil,
        errors: [],
        recipients: {},
        started_at: Time.current.iso8601,
        completed_at: nil
      }
    )

    Rails.logger.info("[CampaignPlanner] initialized campaign=#{campaign.id} delivery_state=#{campaign.reload.delivery_state.inspect}")
    # Inicia la ejecución del primer lote
    Campaigns::ProcessBatchJob.perform_later(campaign)
  end

  private

  def fetch_audience_contacts
    audience_label_ids = campaign.audience.select { |aud| aud['type'] == 'Label' }.pluck('id')
    labels = campaign.account.labels.where(id: audience_label_ids).pluck(:title)
    return campaign.account.contacts.none if labels.empty?

    directly_tagged_ids = campaign.account.contacts.tagged_with(labels, any: true).pluck(:id)
    via_conversation_ids = campaign.account.conversations.tagged_with(labels, any: true).pluck(:contact_id).compact.uniq
    campaign.account.contacts.where(id: (directly_tagged_ids + via_conversation_ids).uniq)
  end
end
