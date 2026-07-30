require 'ssrf_filter'

class Evolution::AudienceOptionsService
  ALLOWED_SCHEMES = %w[http https].freeze
  REQUEST_TIMEOUT = 10
  PRIVACY_MODES = %w[all block allow].freeze

  def initialize(inbox)
    @inbox = inbox
    @config = inbox.channel.try(:additional_attributes) || {}
    @webhook_url = inbox.channel.try(:webhook_url)
  end

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

  def build_result(response)
    ok = response.is_a?(Net::HTTPSuccess)
    { success: ok, message: ok ? 'ok' : "http_#{response&.code}" }
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

  # El host sale del webhook_url, que es un campo editable por el admin, así que
  # la petición se hace con SsrfFilter: valida el esquema y resuelve el host,
  # rechazando IPs privadas/loopback/link-local. Sin eso, apuntar el webhook a
  # una IP interna convertiría a Chatwoot en un proxy hacia la red del servidor
  # (y filtraría la apikey al host elegido).
  def request(url, method: :get, query: {}, body: nil)
    full_url = query.present? ? "#{url}?#{query.to_query}" : url
    headers = { 'apikey' => api_key }
    headers['Content-Type'] = 'application/json' if body
    json_body = body&.to_json

    if allow_private_network?
      request_via_net_http(full_url, method, headers, json_body)
    else
      request_via_ssrf_filter(full_url, method, headers, json_body)
    end
  rescue SsrfFilter::Error, Resolv::ResolvError, URI::InvalidURIError => e
    Rails.logger.warn("Evolution audience options: unsafe or invalid URL (#{e.class})")
    nil
  rescue StandardError => e
    ChatwootExceptionTracker.new(e).capture_exception
    nil
  end

  def request_via_ssrf_filter(url, method, headers, json_body)
    http_options = { open_timeout: REQUEST_TIMEOUT, read_timeout: REQUEST_TIMEOUT }

    if method == :post
      SsrfFilter.post(url, headers: headers, body: json_body, http_options: http_options)
    else
      SsrfFilter.get(url, headers: headers, http_options: http_options)
    end
  end

  # Solo para desarrollo contra una instancia local de Evolution, que
  # SsrfFilter rechazaría por ser loopback. Nunca activar en producción
  # (ver EVOLUTION_ALLOW_PRIVATE_NETWORK en allow_private_network?).
  def request_via_net_http(url, method, headers, json_body)
    uri = URI.parse(url)
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = uri.scheme == 'https'
    req = method == :post ? Net::HTTP::Post.new(uri) : Net::HTTP::Get.new(uri)
    headers.each { |key, value| req[key] = value }
    req.body = json_body if json_body
    http.request(req)
  end

  def allow_private_network?
    ENV.fetch('EVOLUTION_ALLOW_PRIVATE_NETWORK', 'false') == 'true'
  end

  def configured?
    base_url.present? && api_key.present? && instance_name.present?
  end

  # Evolution arma el webhook_url del inbox como
  # "{base_url}/chatwoot/webhook/{instanceName}" al conectar el canal (ver
  # initInstanceChatwoot en su chatwoot.service.ts). En vez de volver a pedir la
  # URL y el nombre de instancia, se derivan de ahí — solo la apikey no se puede
  # deducir.
  def parsed_webhook_uri
    return @parsed_webhook_uri if defined?(@parsed_webhook_uri)

    @parsed_webhook_uri = nil
    return @parsed_webhook_uri if @webhook_url.blank?

    uri = URI.parse(@webhook_url)
    @parsed_webhook_uri = uri if ALLOWED_SCHEMES.include?(uri.scheme) && uri.host.present?
    @parsed_webhook_uri
  rescue URI::InvalidURIError
    @parsed_webhook_uri = nil
  end

  # Conserva el prefijo de path, para instalaciones donde Evolution vive en un
  # subpath detrás de un reverse proxy (".../evo/chatwoot/webhook/instancia").
  def base_url
    uri = parsed_webhook_uri
    return nil if uri.nil?

    port_suffix = uri.port == uri.default_port ? '' : ":#{uri.port}"
    prefix = path_segments[0...-3].join('/')
    "#{uri.scheme}://#{uri.host}#{port_suffix}#{prefix.present? ? "/#{prefix}" : ''}"
  end

  def instance_name
    segment = path_segments.last
    return nil if segment.blank?

    # CGI.unescape traduciría "+" a espacio, rompiendo nombres que lo contengan.
    URI::DEFAULT_PARSER.unescape(segment)
  end

  def path_segments
    @path_segments ||= (parsed_webhook_uri&.path || '').split('/').reject(&:blank?)
  end

  # El nombre puede traer espacios u otros caracteres (ej. "EAJ - PNV"), así que
  # hay que re-codificarlo al armar la URL hacia Evolution.
  def encoded_instance_name
    ERB::Util.url_encode(instance_name)
  end

  def api_key
    @config['evolution_api_key']
  end
end
