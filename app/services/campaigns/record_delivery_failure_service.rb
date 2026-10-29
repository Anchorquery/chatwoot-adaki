# ProcessBatchJob anota al destinatario como 'sent' en cuanto crea el mensaje,
# pero el envío real a Evolution ocurre después (webhook programado). Cuando ese
# envío falla, aquí se corrige el resultado de la campaña: el destinatario pasa a
# 'failed' (y entra en "Reintentar fallidos") y los contadores se ajustan.
#
# Un fallo 463 (cuenta restringida para iniciar chats) queda como no
# reintentable: volver a escribir cuenta como otro contacto en frío.
class Campaigns::RecordDeliveryFailureService
  NON_RETRYABLE_ERROR = /\b463\b/

  pattr_initialize [:message!, :error!]

  def perform
    campaign = conversation&.campaign
    return if campaign.blank?
    return unless campaign.message_of_campaign?(message)

    campaign.with_lock do
      state = campaign.delivery_state.to_h.with_indifferent_access
      entry = state[:recipients].to_h[recipient_key].to_h
      # `next` (no `return`) para que la transacción del lock haga commit.
      next if entry.blank? || entry['status'] == 'failed'

      # update! falla en una campaña completed (prevent_completed_campaign_from_update),
      # que es justo cuando suelen llegar los fallos de entrega de los últimos mensajes.
      campaign.update_columns(delivery_state: failed_state(state, entry), updated_at: Time.current) # rubocop:disable Rails/SkipsModelValidations
    end
  end

  private

  def conversation
    message.conversation
  end

  def recipient_key
    conversation.contact_id.to_s
  end

  def failed_state(state, entry)
    state[:recipients] = state[:recipients].to_h.merge(recipient_key => failed_entry(entry))
    state[:sent_count] = [state[:sent_count].to_i - 1, 0].max if entry['status'] == 'sent'
    state[:failed_count] = state[:failed_count].to_i + 1
    state[:errors] = Array(state[:errors]) + [error_entry]
    state
  end

  def failed_entry(entry)
    failed_entry = entry.merge('status' => 'failed', 'failed_at' => Time.current.iso8601, 'error' => reason)
    failed_entry['retryable'] = false if reason.match?(NON_RETRYABLE_ERROR)
    failed_entry
  end

  def error_entry
    { contact_id: conversation.contact_id, error: reason, time: Time.current }
  end

  def reason
    @reason ||= error.to_s.first(500)
  end
end
