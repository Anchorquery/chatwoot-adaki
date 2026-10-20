# ProcessBatchJob anota al destinatario como 'sent' en cuanto crea el mensaje,
# pero el envío real a Evolution ocurre después (webhook programado). Cuando ese
# envío falla, aquí se corrige el resultado de la campaña: el destinatario pasa a
# 'failed' (y entra en "Reintentar fallidos") y los contadores se ajustan.
class Campaigns::RecordDeliveryFailureService
  pattr_initialize [:message!, :error!]

  def perform
    conversation = message.conversation
    campaign = conversation&.campaign
    return if campaign.blank?

    campaign.with_lock do
      state = campaign.delivery_state.to_h.with_indifferent_access
      recipients = state[:recipients].to_h
      key = conversation.contact_id.to_s
      entry = recipients[key].to_h
      # `next` (no `return`) para que la transacción del lock haga commit.
      next if entry.blank? || entry['status'] == 'failed'

      recipients[key] = entry.merge('status' => 'failed', 'failed_at' => Time.current.iso8601, 'error' => error.to_s.first(500))
      state[:recipients] = recipients
      state[:sent_count] = [state[:sent_count].to_i - 1, 0].max if entry['status'] == 'sent'
      state[:failed_count] = state[:failed_count].to_i + 1
      state[:errors] = Array(state[:errors]) + [{ contact_id: conversation.contact_id, error: error.to_s.first(500), time: Time.current }]
      campaign.update!(delivery_state: state)
    end
  end
end
