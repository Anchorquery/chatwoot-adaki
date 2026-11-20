# Cuenta, sin crear nada, a quién llegaría una campaña con esta audiencia:
# contactos de etiquetas, chats de WhatsApp, números sueltos, excluidos y
# cuántos serían contactos en frío (nunca escribieron a la bandeja). Es lo que
# el formulario enseña antes de lanzar; el envío real lo decide
# Campaigns::DeliveryPlannerService con las mismas reglas.
class Campaigns::AudiencePreviewService
  pattr_initialize [:account!, :inbox!, :audience!, :delivery_settings]

  def perform
    {
      label_contacts: label_ids.size,
      excluded: (excluded_ids & (label_ids + existing_phones.keys)).size,
      chats: chat_count,
      phones: valid_phones.size,
      invalid_phones: normalized_phones.count(&:nil?),
      new_phone_contacts: new_phone_count,
      cold_contacts: cold_count,
      allow_new_contacts: allow_new_contacts?,
      daily_new_contacts_limit: daily_limit,
      total: total,
      reachable: allow_new_contacts? ? total : total - cold_count
    }
  end

  private

  def entries
    @entries ||= Array(audience).map { |entry| entry.to_h.stringify_keys }
  end

  def entries_of(type)
    entries.select { |entry| entry['type'] == type }
  end

  def label_ids
    @label_ids ||= Campaigns::LabelAudience.contact_ids(account, audience)
  end

  def excluded_ids
    @excluded_ids ||= Campaigns::LabelAudience.excluded_contact_ids(account, audience)
  end

  def normalized_phones
    @normalized_phones ||= entries_of(Campaigns::DirectAudienceService::PHONE_TYPE).map do |entry|
      Campaigns::DirectAudienceService.normalize_phone(entry['id'])
    end
  end

  def valid_phones
    @valid_phones ||= normalized_phones.compact.uniq
  end

  # id => teléfono de los números sueltos que ya son contactos.
  def existing_phones
    @existing_phones ||= account.contacts.where(phone_number: valid_phones).pluck(:id, :phone_number).to_h
  end

  def contact_ids
    @contact_ids ||= (label_ids + existing_phones.keys).uniq - excluded_ids
  end

  def new_phone_count
    (valid_phones - existing_phones.values).size
  end

  def chat_count
    entries_of(Campaigns::DirectAudienceService::CHAT_TYPE).count { |entry| Campaigns::DirectAudienceService.chat_jid?(entry['id']) }
  end

  def total
    contact_ids.size + new_phone_count + chat_count
  end

  def cold_count
    @cold_count ||= (contact_ids - known_contact_ids).size + new_phone_count
  end

  # Mismo criterio que Campaigns::NewContactInboxService: conocido es quien
  # escribió alguna vez a esta bandeja, o un grupo/canal ya vinculado.
  def known_contact_ids
    return [] if contact_ids.empty?

    wrote = Message.incoming.where(inbox_id: inbox.id)
                   .joins(:conversation).where(conversations: { contact_id: contact_ids })
                   .distinct.pluck('conversations.contact_id')
    chats = account.contacts.where(id: contact_ids)
                   .where('identifier LIKE ? OR identifier LIKE ?', '%@g.us', '%@newsletter').pluck(:id)
    (wrote + chats).uniq
  end

  def allow_new_contacts?
    ActiveModel::Type::Boolean.new.cast(delivery_settings.to_h.stringify_keys['allow_new_contacts']) || false
  end

  def daily_limit
    limit = delivery_settings.to_h.stringify_keys['max_new_contacts_per_day'].to_i
    limit.positive? ? limit : Campaigns::NewContactInboxService::DEFAULT_DAILY_LIMIT
  end
end
