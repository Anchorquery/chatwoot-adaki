class Campaigns::DeliveryPlannerService
  pattr_initialize [:campaign!]

  def perform
    return if campaign.completed?

    contacts = fetch_audience_contacts
    if contacts.empty?
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
        errors: []
      }
    )

    # Inicia la ejecución del primer lote
    Campaigns::ProcessBatchJob.perform_later(campaign)
  end

  private

  def fetch_audience_contacts
    audience_label_ids = campaign.audience.select { |aud| aud['type'] == 'Label' }.pluck('id')
    labels = campaign.account.labels.where(id: audience_label_ids).pluck(:title)
    campaign.account.contacts.tagged_with(labels, any: true)
  end
end
