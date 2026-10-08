# Base de los servicios que hablan con la instancia de Evolution de UNA
# bandeja. La URL y el nombre de instancia se derivan del webhook_url de la
# bandeja; la apikey se guarda en sus additional_attributes.
#
# Timeouts y SSRF: ver Evolution::HttpClient. Las cadenas de dos llamadas
# (find + set del filtro de privacidad) quedan en ~14s, bajo los 15s de
# Rack::Timeout.
class Evolution::InboxClient
  include Evolution::HttpClient

  ALLOWED_SCHEMES = %w[http https].freeze

  def initialize(inbox)
    @inbox = inbox
    @config = inbox.channel.try(:additional_attributes) || {}
    @webhook_url = inbox.channel.try(:webhook_url)
    # evolution_audience_options comparte esta instancia entre varios threads.
    # La memoizacion de parsed_webhook_uri escribe un nil intermedio antes de
    # parsear: un thread que entrara justo ahi veia "sin webhook" y devolvia su
    # lista vacia. Se resuelve aca, antes de que exista concurrencia.
    parsed_webhook_uri
  end

  # La bandeja está vinculada a una instancia de Evolution que Chatwoot puede
  # operar (con su apikey o con la global). Lo usa el front para decidir
  # dónde mostrar QR, estado y filtro de chats.
  def linked?
    configured?
  end

  private

  # El host sale del webhook_url, que es un campo editable por el admin: por
  # eso la petición pasa por SsrfFilter (ver Evolution::HttpClient).
  def request(url, method: :get, query: {}, body: nil)
    evolution_request(url, api_key: api_key, method: method, query: query, body: body)
  end

  def build_result(response)
    ok = response.is_a?(Net::HTTPSuccess)
    { success: ok, message: ok ? 'ok' : "http_#{response&.code}" }
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

  # La apikey propia de la bandeja (token de su instancia, o la que se pegó a
  # mano) y, si no hay, la global de Super Admin: con ella Evolution permite
  # operar cualquier instancia, así que las bandejas vinculadas desde el
  # Manager funcionan sin pegarles nada.
  def api_key
    @config['evolution_api_key'].presence || global_api_key
  end

  # Solo si el webhook de la bandeja apunta al MISMO servidor configurado en
  # Super Admin. El webhook_url lo puede editar un admin: sin esta comprobación,
  # apuntarlo a otro host le mandaría allí la clave global.
  def global_api_key
    return nil unless same_server_as_configured?

    GlobalConfigService.load('EVOLUTION_API_KEY', '').presence
  end

  def same_server_as_configured?
    configured_url = GlobalConfigService.load('EVOLUTION_API_URL', '').to_s.chomp('/')
    return false if configured_url.blank? || base_url.blank?

    normalize_server_url(configured_url) == normalize_server_url(base_url)
  end

  def normalize_server_url(url)
    uri = URI.parse(url)
    return nil unless ALLOWED_SCHEMES.include?(uri.scheme) && uri.host.present?

    [uri.scheme, uri.host.downcase, uri.port, uri.path.to_s.chomp('/')]
  rescue URI::InvalidURIError
    nil
  end
end
