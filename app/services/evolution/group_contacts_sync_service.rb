# Da de alta como contactos los grupos de WhatsApp del número vinculado a una
# bandeja de Evolution, para poder abrirles una conversación desde Chatwoot sin
# esperar a que alguien escriba primero en el grupo.
#
# Evolution solo crea el contacto de un grupo cuando le llega un mensaje de ese
# grupo. Hasta entonces no hay a quién elegir en "Nueva conversación". Con el
# contacto creado, el envío ya funciona: Evolution manda cada mensaje saliente
# al identifier del contacto, que para un grupo es su JID ("...@g.us").
#
# El contacto se crea igual que lo haría Evolution (identifier = JID, nombre
# "<asunto> (GROUP)", sin teléfono), porque Evolution busca el contacto de un
# grupo por identifier exacto: si no coincide, crearía un duplicado al recibir
# el primer mensaje.
class Evolution::GroupContactsSyncService < Evolution::InboxClient
  GROUP_SUFFIX = '@g.us'.freeze
  NAME_SUFFIX = ' (GROUP)'.freeze

  def perform
    return failure('not_configured') unless configured?

    response = request("#{base_url}/group/fetchAllGroups/#{encoded_instance_name}", query: { getParticipants: 'false' })
    return failure(response.nil? ? 'unsafe_url' : "http_#{response.code}") unless response.is_a?(Net::HTTPSuccess)

    { success: true, **sync(parse_groups(response.body)) }
  rescue JSON::ParserError
    failure('invalid_response')
  end

  private

  def parse_groups(body)
    groups = Array.wrap(JSON.parse(body)).filter_map do |group|
      next unless group.is_a?(Hash)

      jid = group['id'].to_s
      { jid: jid, subject: group['subject'].to_s.strip } if jid.end_with?(GROUP_SUFFIX)
    end
    groups.uniq { |group| group[:jid] }
  end

  def sync(groups)
    counts = { total: groups.size, created: 0, existing: 0, failed: 0 }
    groups.each { |group| counts[sync_group(group)] += 1 }
    counts
  end

  def sync_group(group)
    contact = account.contacts.find_by(identifier: group[:jid])
    status = contact ? :existing : :created
    contact ||= account.contacts.create!(identifier: group[:jid], name: group_name(group))
    fill_missing_name(contact, group)
    link_to_inbox(contact)
    status
  rescue ActiveRecord::RecordNotUnique, ActiveRecord::RecordInvalid => e
    Rails.logger.warn("[EvolutionGroupContacts] inbox=#{@inbox.id} group=#{group[:jid]}: #{e.message}")
    :failed
  end

  # Solo se completa un nombre vacío o igual al JID: si alguien renombró el
  # contacto en Chatwoot, ese nombre se respeta.
  def fill_missing_name(contact, group)
    return unless contact.name.blank? || contact.name == group[:jid]

    contact.update!(name: group_name(group))
  end

  def link_to_inbox(contact)
    return if @inbox.contact_inboxes.exists?(contact: contact)

    ContactInboxBuilder.new(contact: contact, inbox: @inbox).perform
  end

  def group_name(group)
    group[:subject].present? ? "#{group[:subject]}#{NAME_SUFFIX}" : group[:jid]
  end

  def account
    @inbox.account
  end

  def failure(message)
    { success: false, message: message }
  end
end
