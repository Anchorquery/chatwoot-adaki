require 'ssrf_filter'

class Evolution::AudienceOptionsService
  ALLOWED_SCHEMES = %w[http https].freeze
  REQUEST_TIMEOUT = 10

  def initialize(inbox)
    @inbox = inbox
    @config = inbox.channel.try(:additional_attributes) || {}
    @webhook_url = inbox.channel.try(:webhook_url)
  end

  def newsletters
    fetch('newsletter/find')
  end

  def groups
    fetch('group/fetchAllGroups', getParticipants: 'false')
  end

  def test_connection
    return { success: false, message: 'not_configured' } unless configured?

    response = request("#{base_url}/instance/connectionState/#{encoded_instance_name}")
    return { success: false, message: 'unsafe_url' } if response.nil?

    ok = response.is_a?(Net::HTTPSuccess)
    { success: ok, message: ok ? 'ok' : "http_#{response.code}" }
  end

  private

  def fetch(path, query = {})
    return [] unless configured?

    response = request("#{base_url}/#{path}/#{encoded_instance_name}", query)
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
  def request(url, query = {})
    full_url = query.present? ? "#{url}?#{query.to_query}" : url
    http_options = { open_timeout: REQUEST_TIMEOUT, read_timeout: REQUEST_TIMEOUT }

    if allow_private_network?
      # Solo para desarrollo contra una instancia local de Evolution, que
      # SsrfFilter rechazaría por ser loopback. Nunca activar en producción.
      Net::HTTP.get_response(URI.parse(full_url), { 'apikey' => api_key })
    else
      SsrfFilter.get(full_url, headers: { 'apikey' => api_key }, http_options: http_options)
    end
  rescue SsrfFilter::Error, Resolv::ResolvError, URI::InvalidURIError => e
    Rails.logger.warn("Evolution audience options: unsafe or invalid URL (#{e.class})")
    nil
  rescue StandardError => e
    ChatwootExceptionTracker.new(e).capture_exception
    nil
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
