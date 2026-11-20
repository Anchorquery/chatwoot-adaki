# Destinatarios de una campaña que no salen de una etiqueta:
#
# - WhatsappChat: un grupo, el grupo de avisos de una comunidad o un canal de
#   WhatsApp, elegido de la lista que da Evolution. Puede que todavía no tenga
#   conversación en Chatwoot (Evolution solo la crea cuando llega un mensaje),
#   así que se crea el contacto con el JID como identifier, que es lo que usa
#   Evolution para saber a qué chat enviar, y se vincula a la bandeja.
# - Phone: un número suelto que no hace falta tener como contacto. Se busca por
#   teléfono y, si no existe, se crea. No se vincula aquí: escribirle es
#   escribir en frío y eso lo decide Campaigns::NewContactInboxService
#   (allow_new_contacts y el tope diario).
class Campaigns::DirectAudienceService
  CHAT_TYPE = 'WhatsappChat'.freeze
  PHONE_TYPE = 'Phone'.freeze
  CHAT_SUFFIXES = %w[@g.us @newsletter].freeze
  GROUP_SUFFIX = '@g.us'.freeze

  pattr_initialize [:campaign!]

  def self.direct_entry?(entry)
    [CHAT_TYPE, PHONE_TYPE].include?(entry.to_h.stringify_keys['type'])
  end

  def contact_ids
    entries.filter_map { |entry| resolve(entry) }.uniq
  end

  private

  delegate :account, :inbox, to: :campaign

  def entries
    Array(campaign.audience).map { |entry| entry.to_h.stringify_keys }.select { |entry| self.class.direct_entry?(entry) }
  end

  def resolve(entry)
    entry['type'] == CHAT_TYPE ? resolve_chat(entry) : resolve_phone(entry)
  rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique => e
    Rails.logger.warn("[CampaignDirectAudience] campaign=#{campaign.id} cannot resolve #{entry['type']}: #{e.message}")
    nil
  end

  def resolve_chat(entry)
    jid = entry['id'].to_s.strip
    return unless jid.end_with?(*CHAT_SUFFIXES)

    contact = account.contacts.find_by(identifier: jid) ||
              account.contacts.create!(identifier: jid, name: chat_name(entry, jid))
    ContactInboxBuilder.new(contact: contact, inbox: inbox).perform unless inbox.contact_inboxes.exists?(contact: contact)
    contact.id
  end

  # Mismo nombre que pone Evolution cuando el grupo escribe por primera vez,
  # para que no aparezca un contacto distinto del que ya conoce el equipo.
  def chat_name(entry, jid)
    name = entry['name'].to_s.strip.presence || jid
    jid.end_with?(GROUP_SUFFIX) ? "#{name} (GROUP)" : name
  end

  def resolve_phone(entry)
    phone = normalize_phone(entry['id'])
    return if phone.nil?

    contact = account.contacts.find_by(phone_number: phone) || account.contacts.create!(phone_number: phone, name: phone)
    contact.id
  end

  # Sin prefijo se asume España, como los números que se escriben a mano en la
  # bandeja. Evolution comprueba después si el número tiene WhatsApp.
  def normalize_phone(value)
    digits = value.to_s.gsub(/[^\d+]/, '')
    digits = digits.sub(/\A00/, '+')
    digits = "+34#{digits}" if digits.match?(/\A[6789]\d{8}\z/)
    digits = "+#{digits}" unless digits.start_with?('+')
    digits.match?(/\A\+[1-9]\d{7,14}\z/) ? digits : nil
  end
end
