class Campaigns::DeliveryPlannerService
  pattr_initialize [:campaign!]

  def perform
    Rails.logger.info("[CampaignPlanner] perform START campaign=#{campaign.id} status=#{campaign.campaign_status}")
    return if campaign.completed?
    return unless claim_campaign!

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

  # El envío inmediato y TriggerScheduledItemsJob (cada minuto) pueden encolar
  # el arranque de la misma campaña: solo quien la pasa de active a running la
  # envía. Antes arrancaban las dos, con mensajes duplicados y el doble de carga
  # en Evolution.
  def claim_campaign!
    running = Campaign.campaign_statuses[:running]
    Campaign.where(id: campaign.id, campaign_status: :active)
            .update_all(campaign_status: running, updated_at: Time.current) # rubocop:disable Rails/SkipsModelValidations
            .positive?
  end

  def fetch_audience_contacts
    ids = Campaigns::LabelAudience.contact_ids(campaign.account, campaign.audience) +
          Campaigns::DirectAudienceService.new(campaign: campaign).contact_ids
    ids = ids.uniq - Campaigns::LabelAudience.excluded_contact_ids(campaign.account, campaign.audience)
    return campaign.account.contacts.none if ids.empty?

    # Mismo orden en el que se eligieron: primero etiquetas, luego chats y números.
    contacts_by_id = campaign.account.contacts.where(id: ids).index_by(&:id)
    ids.filter_map { |id| contacts_by_id[id] }
  end
end
