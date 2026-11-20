# "Enviar a pendientes" de la página de resultados: vuelve a poner en marcha una
# campaña para los fallidos reintentables, para los que nunca se procesaron
# (pausada o cortada a medias), o para ambos.
#
# Solo se reintentan los fallidos reintentables. Los omitidos no tienen
# conversación previa con la bandeja, y los 463 o los números sin WhatsApp
# fallarían igual: escribirles en frío es lo que hace que WhatsApp bloquee el
# número. A los ya enviados no se les repite.
#
# Con scope 'failed' o 'skipped' los pendientes se apartan en
# deferred_contact_ids: siguen contando como pendientes en los resultados y
# entran en el siguiente envío.
#
# 'skipped' vuelve a intentar los omitidos por no tener conversación previa.
# Solo sirve después de activar allow_new_contacts: si no, se vuelven a
# omitir sin escribirles.
class Campaigns::ResumeService
  SCOPES = %w[all failed pending skipped].freeze
  RETRY_SCOPES = %w[all failed].freeze
  PENDING_SCOPES = %w[all pending].freeze
  DONE_STATUSES = %w[sent skipped failed].freeze

  Result = Struct.new(:error, :failed_count, :pending_count, keyword_init: true) do
    def total = failed_count.to_i + pending_count.to_i
  end

  pattr_initialize [:campaign!, :scope]

  def self.retryable?(recipient)
    recipient = recipient.to_h
    recipient['status'] == 'failed' && recipient['retryable'] != false
  end

  def self.pending_ids(state)
    state = state.to_h.with_indifferent_access
    recipient_ids = state[:recipients].to_h.keys.map(&:to_i)
    ((state[:contact_ids] || []).map(&:to_i) - recipient_ids) + (state[:deferred_contact_ids] || []).map(&:to_i)
  end

  def perform
    # Una campaña en marcha (o esperando al día siguiente) ya tiene un
    # ProcessBatchJob programado: otro más procesaría los mismos contactos dos veces.
    return Result.new(error: 'Campaign is already running') if campaign.running?

    failed_ids = retry_ids
    pending_ids = self.class.pending_ids(state).uniq - failed_ids
    sending_pending = PENDING_SCOPES.include?(scope_value) ? pending_ids : []
    return Result.new(error: 'No pending contacts to send to') if failed_ids.empty? && sending_pending.empty?

    restart!(failed_ids, sending_pending, pending_ids - sending_pending)
    Result.new(failed_count: failed_ids.size, pending_count: sending_pending.size)
  end

  private

  def scope_value
    SCOPES.include?(scope.to_s) ? scope.to_s : 'all'
  end

  def state
    @state ||= campaign.delivery_state.to_h.with_indifferent_access
  end

  def recipients
    @recipients ||= state[:recipients].to_h
  end

  # Los que se vuelven a procesar desde cero: fallidos reintentables u omitidos.
  def retry_ids
    return skipped_ids if scope_value == 'skipped'
    return all_failed_ids if RETRY_SCOPES.include?(scope_value)

    []
  end

  def all_failed_ids
    recipients.select { |_, recipient| self.class.retryable?(recipient) }.keys.map(&:to_i)
  end

  def skipped_ids
    recipients.select { |_, recipient| recipient['status'] == 'skipped' }.keys.map(&:to_i)
  end

  def restart!(failed_ids, pending_ids, deferred_ids)
    failed_ids.each { |id| recipients.delete(id.to_s) }
    done_ids = recipients.select { |_, recipient| DONE_STATUSES.include?(recipient['status']) }.keys.map(&:to_i)
    contact_ids = done_ids + failed_ids + pending_ids

    campaign.update!(campaign_status: :running, delivery_state: restarted_state(contact_ids, deferred_ids, done_ids.size))
    Campaigns::ProcessBatchJob.perform_later(campaign)
  end

  def restarted_state(contact_ids, deferred_ids, processed_index)
    state.merge(
      contact_ids: contact_ids,
      deferred_contact_ids: deferred_ids,
      total_contacts: contact_ids.size + deferred_ids.size,
      processed_index: processed_index,
      failed_count: recipients.count { |_, recipient| recipient['status'] == 'failed' },
      consecutive_failures: 0,
      recipients: recipients
    )
  end
end
