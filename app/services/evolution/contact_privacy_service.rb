# Atajo del filtro de privacidad para UN contacto, desde la conversación:
# "que los mensajes de este chat dejen de llegar a Chatwoot" (o que vuelvan).
#
# No cambia el modo del filtro: en modo "bloquear" (o "todos") añade el
# contacto a los excluidos; en modo "solo seleccionados" lo quita de los
# permitidos. Así el resultado es el que el agente espera sin tocar al resto.
class Evolution::ContactPrivacyService < Evolution::AudienceOptionsService
  def initialize(inbox, contact)
    super(inbox)
    @contact = contact
  end

  # Los JIDs con los que Evolution puede identificar este chat: el del
  # contacto (teléfono o "@lid") y el de su teléfono. El filtro de Evolution
  # compara contra ambos (remoteJid y remoteJidAlt).
  def contact_jids
    identifier = @contact.identifier.to_s
    phone = @contact.phone_number.to_s.gsub(/\D/, '')
    [phone.present? ? "#{phone}@s.whatsapp.net" : nil, identifier.include?('@') ? identifier : nil].compact.uniq
  end

  def status
    return { status: 'not_configured' } unless configured?
    return { status: 'no_jid' } if contact_jids.empty?

    config = read_config
    return { status: config } if config.is_a?(String)

    allowed = privacy_jids(config, 'allowedJids')
    ignored = privacy_jids(config, 'ignoreJids')
    filtered = allowed.any? ? !matches_any?(allowed) : matches_any?(ignored)
    { status: 'ok', filtered: filtered, mode: filter_mode(allowed, ignored) }
  end

  def update(filtered:)
    return { success: false, message: 'not_configured' } unless configured?
    return { success: false, message: 'no_jid' } if contact_jids.empty?

    config = read_config
    return { success: false, message: config } if config.is_a?(String)

    allowed = privacy_jids(config, 'allowedJids')
    ignored = privacy_jids(config, 'ignoreJids')
    if allowed.any?
      allowed = toggle(allowed, add: !filtered)
      # Una lista de permitidos vacía significa "recibir todo": quitar al último
      # permitido abriría la bandeja a todos los chats, justo lo contrario.
      return { success: false, message: 'last_allowed' } if allowed.empty?
    else
      ignored = toggle(ignored, add: filtered)
    end

    payload = config.merge('allowedJids' => allowed, 'ignoreJids' => ignored)
                    .except('createdAt', 'updatedAt', 'id', 'instanceId', 'webhook_url')
    build_result(request("#{base_url}/chatwoot/set/#{encoded_instance_name}", method: :post, body: payload))
  end

  private

  # Devuelve el Hash de la integración o un código de error (String).
  def read_config
    response = request("#{base_url}/chatwoot/find/#{encoded_instance_name}")
    return 'unreachable' unless response.is_a?(Net::HTTPSuccess)

    data = parse_json(response)
    data.is_a?(Hash) ? data : 'invalid_response'
  end

  # Añadir: el JID principal del contacto (si ya está en alguna forma, no se
  # duplica). Quitar: todas sus variantes, incluido el número pelado que
  # guarda el Manager de Evolution.
  def toggle(list, add:)
    return list.reject { |jid| variant?(jid) } unless add
    return list if matches_any?(list)

    list + [contact_jids.first]
  end

  def filter_mode(allowed, ignored)
    return 'allow' if allowed.any?

    ignored.any? ? 'block' : 'all'
  end

  def matches_any?(list)
    list.any? { |jid| variant?(jid) }
  end

  def variant?(jid)
    variants.include?(jid.to_s)
  end

  def variants
    @variants ||= contact_jids.flat_map { |jid| [jid, jid.end_with?('@s.whatsapp.net') ? jid.split('@').first : nil] }.compact
  end
end
