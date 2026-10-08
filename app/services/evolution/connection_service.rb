# Sesión de WhatsApp de una bandeja vinculada a Evolution: estado, QR para
# vincular el teléfono, desconexión y borrado de la instancia.
class Evolution::ConnectionService < Evolution::InboxClient
  # Estado de la sesión de WhatsApp: 'open' (conectada), 'connecting'
  # (esperando que escaneen el QR) o 'close'. Si está abierta, se suma el
  # número y el nombre del perfil para que el admin vea QUÉ cuenta está
  # vinculada, no solo que hay una.
  def connection_state
    return { status: 'not_configured' } unless configured?

    response = request("#{base_url}/instance/connectionState/#{encoded_instance_name}")
    return { status: failure_status(response) } unless response.is_a?(Net::HTTPSuccess)

    data = parse_json(response)
    state = data.is_a?(Hash) ? data.dig('instance', 'state').to_s : ''
    return { status: 'invalid_response' } if state.blank?

    result = { status: 'ok', state: state }
    state == 'open' ? result.merge(connected_profile) : result
  end

  # Pide a Evolution que arranque la sesión y devuelve el QR vigente. Con la
  # sesión ya abierta Evolution responde el estado en vez de un QR. Baileys
  # rota el QR cada ~20s: el front vuelve a llamar mientras lo muestra.
  def connect
    return { status: 'not_configured' } unless configured?

    response = request("#{base_url}/instance/connect/#{encoded_instance_name}")
    return { status: failure_status(response) } unless response.is_a?(Net::HTTPSuccess)

    data = parse_json(response)
    return { status: 'invalid_response' } unless data.is_a?(Hash)
    # connectToWhatsapp rescata sus propios errores y responde 200 con esto.
    return { status: 'evolution_error' } if data['error'] == true

    build_connect_result(data)
  end

  # Cierra la sesión de WhatsApp (desvincula el dispositivo). La instancia
  # sigue existiendo: se puede volver a escanear otro QR.
  def logout
    return { success: false, message: 'not_configured' } unless configured?

    build_result(request("#{base_url}/instance/logout/#{encoded_instance_name}", method: :delete))
  end

  # Borra la instancia en Evolution. Solo para bandejas cuya instancia creó
  # Chatwoot: una instancia huérfana se queda reintentando la conexión, y las
  # atascadas en 'connecting' son las que más memoria comen en Evolution.
  def delete_instance
    return { success: false, message: 'not_configured' } unless configured?

    build_result(request("#{base_url}/instance/delete/#{encoded_instance_name}", method: :delete))
  end

  # Reinicia la conexión con WhatsApp sin desvincular el teléfono. Útil cuando
  # la sesión se queda colgada en 'connecting'.
  def restart
    return { success: false, message: 'not_configured' } unless configured?

    response = request("#{base_url}/instance/restart/#{encoded_instance_name}", method: :post)
    return build_result(response) unless response.is_a?(Net::HTTPSuccess)
    # restartInstance rescata sus propios errores y responde 200 con esto.
    return { success: false, message: 'evolution_error' } if parse_json(response).try(:[], 'error') == true

    { success: true, message: 'ok' }
  end

  # Ajustes de la instancia que hoy solo se ven en el Manager de Evolution.
  # Evolution responde 200 con cuerpo null cuando no puede leerlos: eso es un
  # fallo, nunca "todo apagado" (el admin guardaría encima la config real).
  def instance_settings
    return { status: 'not_configured' } unless configured?

    settings = fetch_instance_settings
    return { status: settings } if settings.is_a?(String)

    { status: 'ok', settings: settings.slice(*SETTINGS_FIELDS.values).transform_keys(&SETTINGS_FIELDS.invert) }
  end

  # /settings/set reescribe el registro entero y exige los seis booleanos: se
  # lee lo vigente y solo se pisan los campos que la UI gestiona, para no
  # perder los demás (syncFullHistory, wavoipToken).
  def update_instance_settings(changes)
    return { success: false, message: 'not_configured' } unless configured?

    current = fetch_instance_settings
    return { success: false, message: current } if current.is_a?(String)

    payload = current.merge(normalize_settings(changes))
    build_result(request("#{base_url}/settings/set/#{encoded_instance_name}", method: :post, body: payload))
  end

  private

  # Nombre en la API de Chatwoot => nombre en Evolution.
  SETTINGS_FIELDS = {
    'reject_call' => 'rejectCall',
    'msg_call' => 'msgCall',
    'groups_ignore' => 'groupsIgnore',
    'newsletter_ignore' => 'newsletterIgnore',
    'always_online' => 'alwaysOnline',
    'read_messages' => 'readMessages',
    'read_status' => 'readStatus'
  }.freeze
  REQUIRED_SETTINGS = %w[rejectCall groupsIgnore alwaysOnline readMessages readStatus syncFullHistory].freeze

  # Devuelve el Hash de Evolution o el código de error como String.
  def fetch_instance_settings
    response = request("#{base_url}/settings/find/#{encoded_instance_name}")
    return failure_status(response) unless response.is_a?(Net::HTTPSuccess)

    data = parse_json(response)
    return 'invalid_response' unless data.is_a?(Hash)

    REQUIRED_SETTINGS.index_with { false }.merge(data.compact)
  end

  def normalize_settings(changes)
    changes.to_h.stringify_keys.slice(*SETTINGS_FIELDS.keys).each_with_object({}) do |(key, value), result|
      evolution_key = SETTINGS_FIELDS[key]
      result[evolution_key] = key == 'msg_call' ? value.to_s.strip.first(500) : ActiveModel::Type::Boolean.new.cast(value) == true
    end
  end

  def failure_status(response)
    response.nil? ? 'unreachable' : "http_#{response.code}"
  end

  def build_connect_result(data)
    state = data.dig('instance', 'state') || data.dig('instance', 'status')
    return { status: 'ok', state: 'open' }.merge(connected_profile) if state == 'open'

    { status: 'ok', state: 'connecting', qr_code: safe_qr_image(data['base64']), pairing_code: data['pairingCode'].presence }
  end

  # El QR va directo a un <img src>: solo se acepta una imagen en data URI,
  # nunca una URL arbitraria que Evolution (o quien responda en su lugar)
  # pudiera colar.
  def safe_qr_image(value)
    value.is_a?(String) && value.start_with?('data:image/') ? value : nil
  end

  # fetchInstances acepta la apikey de la instancia y la filtra a esa sola.
  # Es un extra para la UI: si falla, el estado 'open' se informa igual.
  def connected_profile
    data = parse_json(request("#{base_url}/instance/fetchInstances", query: { instanceName: instance_name }))
    instance = Array.wrap(data).find { |item| item.is_a?(Hash) }
    return {} if instance.nil?

    {
      phone_number: instance['ownerJid'].to_s.split('@').first.presence,
      profile_name: instance['profileName'].presence,
      profile_picture_url: instance['profilePicUrl'].presence
    }.compact
  end
end
