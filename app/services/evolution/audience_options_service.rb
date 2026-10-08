# Audiencias (grupos, canales, contactos) y filtro de privacidad de una
# bandeja vinculada a Evolution. Conexión y QR: Evolution::ConnectionService.
class Evolution::AudienceOptionsService < Evolution::InboxClient
  PRIVACY_MODES = %w[all block allow].freeze

  def newsletters
    fetch('newsletter/find')
  end

  def groups
    fetch('group/fetchAllGroups', query: { getParticipants: 'false' })
  end

  # Chats individuales (sin grupos ni canales), para el picker de privacidad.
  # Tope duro: sin esto, una cuenta con miles de contactos hace timeout (10s)
  # contra Evolution y el picker queda vacio en silencio. Para listas mas
  # grandes, el buscador paginado del Manager de Evolution es la herramienta
  # correcta — este panel es para el uso diario de un agente, no reemplaza
  # eso.
  CONTACTS_LIMIT = 200

  def contacts
    result = fetch('chat/findChats', method: :post, body: { where: {}, take: CONTACTS_LIMIT, skip: 0 })
    # select antes de reject: un elemento que no sea un Hash (Evolution devolviendo
    # algo inesperado, ej. null en la lista) tiraba NoMethodError sin rescatar en
    # chat['remoteJid'] y tumbaba el endpoint entero con 500.
    Array.wrap(result).select { |chat| chat.is_a?(Hash) }.reject do |chat|
      jid = chat['remoteJid'].to_s
      jid.end_with?('@g.us', '@newsletter') || jid == 'status@broadcast'
    end
  end

  # Búsqueda paginada para el filtro de privacidad. A diferencia de #contacts,
  # el término viaja a Evolution (findChats del fork filtra en SQL por nombre,
  # por JID y por el teléfono de los chats "@lid") y no hay tope de 200: se
  # pide de página en página. Devuelve las filas crudas, sin filtrar por tipo.
  def search_chats(query:, take:, skip:)
    where = query.present? ? { pushName: query } : {}
    rows = fetch('chat/findChats', method: :post, body: { where: where, take: take, skip: skip })
    Array.wrap(rows).select { |chat| chat.is_a?(Hash) }
  end

  # Búsqueda en la agenda del número (findContacts del fork con `search` y
  # `onlySaved`): parcial por nombre y teléfono, en SQL y paginada. Mucho más
  # barata que findChats, que agrupa toda la tabla de mensajes, y encuentra
  # también a quien nunca escribió.
  def search_contacts(query:, take:, page:)
    where = { onlySaved: true }
    where[:search] = query if query.present?
    rows = fetch('chat/findContacts', method: :post, body: { where: where, offset: take, page: page })
    Array.wrap(rows).select { |contact| contact.is_a?(Hash) }
  end

  # Contactos de la agenda por JID, en una sola llamada (findContacts del fork
  # con `remoteJids`). `offset` acota la respuesta: un Evolution sin ese
  # parámetro lo ignoraría y devolvería la agenda entera.
  def contacts_by_jids(jids)
    jids = Array(jids).first(500)
    return [] if jids.empty?

    rows = fetch('chat/findContacts', method: :post, body: { where: { remoteJids: jids }, offset: [jids.size * 2, 1000].min, page: 1 })
    Array.wrap(rows).select { |contact| contact.is_a?(Hash) }
  end

  def test_connection
    return { success: false, message: 'not_configured' } unless configured?

    response = request("#{base_url}/instance/connectionState/#{encoded_instance_name}")
    return { success: false, message: 'unsafe_url' } if response.nil?

    ok = response.is_a?(Net::HTTPSuccess)
    { success: ok, message: ok ? 'ok' : "http_#{response.code}" }
  end

  EMPTY_FILTER = { mode: 'all', group_jids: [], channel_jids: [], contact_jids: [] }.freeze

  # Evolution guarda ignoreJids/allowedJids dentro de SU PROPIA config de la
  # integración con Chatwoot (GET /chatwoot/find/{instance}) — Chatwoot no
  # necesita (ni debe) duplicar ese estado en su propia base.
  #
  # Nunca devuelve el filtro vacío como fallback ante un error: "no pude leer" y
  # "no hay filtro" se ven idénticos en la UI, y el usuario guardaría encima
  # borrando la config real. Los fallos salen con :status y el controller los
  # convierte en un HTTP de error.
  def current_privacy_filter
    return { status: 'not_configured' } unless configured?

    response = request("#{base_url}/chatwoot/find/#{encoded_instance_name}")
    return { status: 'unreachable' } unless response.is_a?(Net::HTTPSuccess)

    build_privacy_filter(JSON.parse(response.body))
  rescue JSON::ParserError
    { status: 'invalid_response' }
  end

  def update_privacy_filter(mode:, jids:)
    return { success: false, message: 'not_configured' } unless configured?
    return { success: false, message: 'invalid_mode' } unless PRIVACY_MODES.include?(mode)

    current_response = request("#{base_url}/chatwoot/find/#{encoded_instance_name}")
    return { success: false, message: 'evolution_unreachable' } unless current_response.is_a?(Net::HTTPSuccess)

    payload = merge_privacy_filter_into_config(JSON.parse(current_response.body), mode, jids)
    response = request("#{base_url}/chatwoot/set/#{encoded_instance_name}", method: :post, body: payload)
    build_result(response)
  rescue JSON::ParserError
    { success: false, message: 'invalid_response' }
  end

  private

  # Evolution aplica allowedJids e ignoreJids a la vez; esta UI los modela como
  # modos excluyentes. Si vienen los dos (típico: alguien tocó el Manager de
  # Evolution y este panel), se avisa con :conflict en vez de mostrar solo uno y
  # borrar el otro en silencio al guardar.
  def build_privacy_filter(config)
    allowed = privacy_jids(config, 'allowedJids')
    ignored = privacy_jids(config, 'ignoreJids')
    conflict = allowed.any? && ignored.any?

    return { status: 'ok', conflict: conflict, mode: 'allow', **split_jids_by_type(allowed) } if allowed.any?
    return { status: 'ok', conflict: conflict, mode: 'block', **split_jids_by_type(ignored) } if ignored.any?

    { status: 'ok', conflict: false, **EMPTY_FILTER }
  end

  def privacy_jids(config, key)
    Array.wrap(config[key]).map(&:to_s).reject(&:blank?)
  end

  # Se reenvía la config completa porque /chatwoot/set reescribe el registro
  # entero; solo se quitan los campos que Evolution agrega al responder y que su
  # DTO de escritura no espera de vuelta.
  def merge_privacy_filter_into_config(current_config, mode, jids)
    current_config.merge(
      'ignoreJids' => mode == 'block' ? jids : [],
      'allowedJids' => mode == 'allow' ? jids : []
    ).except('createdAt', 'updatedAt', 'id', 'instanceId', 'webhook_url')
  end

  # Reparte los JIDs guardados en las tres cajas del picker por su SUFIJO, no
  # cruzándolos contra las listas vivas de Evolution.
  #
  # Cruzarlas era una fuga de datos: lo guardado que no apareciera en esas
  # listas (un contacto más allá del tope de CONTACTS_LIMIT, un grupo cuando
  # fetchAllGroups daba timeout, o los comodines "@g.us"/"@newsletter"/
  # "@s.whatsapp.net" que Evolution sí soporta) desaparecía de la respuesta, y
  # como el front guarda exactamente lo que muestra, el siguiente guardado lo
  # borraba de Evolution. Además ahorra tres llamadas HTTP en cada lectura.
  #
  # Los JIDs que el picker no reconozca se muestran crudos: TagMultiSelectComboBox
  # cae a { value, label: value } cuando el valor no está entre las opciones.
  def split_jids_by_type(jids)
    grouped = jids.uniq.group_by { |jid| jid_category(jid) }
    {
      group_jids: grouped.fetch(:group, []),
      channel_jids: grouped.fetch(:channel, []),
      contact_jids: grouped.fetch(:contact, [])
    }
  end

  # Un número pelado ("34600111222", como lo guarda el Manager de Evolution) no
  # lleva sufijo y cae en contactos, que es donde corresponde.
  def jid_category(jid)
    return :group if jid.end_with?('@g.us')
    return :channel if jid.end_with?('@newsletter')

    :contact
  end

  def fetch(path, query: {}, method: :get, body: nil)
    return [] unless configured?

    url = "#{base_url}/#{path}/#{encoded_instance_name}"
    response = request(url, method: method, query: query, body: body)
    return [] unless response.is_a?(Net::HTTPSuccess)

    Array.wrap(JSON.parse(response.body))
  rescue JSON::ParserError
    []
  end
end
