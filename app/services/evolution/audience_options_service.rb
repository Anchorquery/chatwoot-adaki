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
  def contacts
    result = fetch('chat/findChats', method: :post, body: { where: {} })
    Array.wrap(result).reject do |chat|
      jid = chat['remoteJid'].to_s
      jid.end_with?('@g.us', '@newsletter')
    end
  end

  def test_connection
    return { success: false, message: 'not_configured' } unless configured?

    response = request("#{base_url}/instance/connectionState/#{encoded_instance_name}")
    return { success: false, message: 'unsafe_url' } if response.nil?

    ok = response.is_a?(Net::HTTPSuccess)
    { success: ok, message: ok ? 'ok' : "http_#{response.code}" }
  end

  # Evolution guarda ignoreJids/allowedJids dentro de SU PROPIA config de la
  # integración con Chatwoot (GET /chatwoot/find/{instance}) — Chatwoot no
  # necesita (ni debe) duplicar ese estado en su propia base.
  def current_privacy_filter
    return { mode: 'all', group_jids: [], channel_jids: [], contact_jids: [] } unless configured?

    response = request("#{base_url}/chatwoot/find/#{encoded_instance_name}")
    config = response.is_a?(Net::HTTPSuccess) ? JSON.parse(response.body) : {}

    allowed = Array.wrap(config['allowedJids'])
    ignored = Array.wrap(config['ignoreJids'])

    if allowed.any?
      { mode: 'allow', **split_jids_by_type(allowed) }
    elsif ignored.any?
      { mode: 'block', **split_jids_by_type(ignored) }
    else
      { mode: 'all', group_jids: [], channel_jids: [], contact_jids: [] }
    end
  rescue JSON::ParserError
    { mode: 'all', group_jids: [], channel_jids: [], contact_jids: [] }
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

  def merge_privacy_filter_into_config(current_config, mode, jids)
    current_config.merge(
      'ignoreJids' => mode == 'block' ? jids : [],
      'allowedJids' => mode == 'allow' ? jids : []
    ).except('createdAt', 'updatedAt', 'id')
  end

  def build_result(response)
    ok = response.is_a?(Net::HTTPSuccess)
    { success: ok, message: ok ? 'ok' : "http_#{response&.code}" }
  end

  # JIDs guardados en Evolution son solo dígitos (normalizados), sin sufijo,
  # así que no queda registrado si eran grupo/canal/contacto. El picker
  # necesita saber a qué categoría pertenece cada uno para mostrar el nombre
  # correcto, así que se resuelve contra las listas actuales de Evolution.
  def split_jids_by_type(jids)
    jid_set = jids.to_set
    {
      group_jids: groups.filter_map { |g| g['id'] if jid_set.include?(strip_suffix(g['id'])) },
      channel_jids: newsletters.filter_map { |n| n['id'] if jid_set.include?(strip_suffix(n['id'])) },
      contact_jids: contacts.filter_map { |c| c['remoteJid'] if jid_set.include?(strip_suffix(c['remoteJid'])) }
    }
  end

  def strip_suffix(jid)
    jid.to_s.split('@').first
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
