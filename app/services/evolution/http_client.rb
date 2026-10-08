require 'ssrf_filter'

# Plumbing HTTP compartido por los servicios que hablan con Evolution API.
#
# Las URLs pueden salir de un campo editable por el admin (el webhook_url de la
# bandeja), así que por defecto la petición pasa por SsrfFilter: valida el
# esquema y resuelve el host, rechazando IPs privadas/loopback/link-local. Sin
# eso, apuntar el webhook a una IP interna convertiría a Chatwoot en un proxy
# hacia la red del servidor (y filtraría la apikey al host elegido).
module Evolution::HttpClient
  # El presupuesto real de una petición es open_timeout + read_timeout: con
  # 2s + 5s el peor caso por llamada es ~7s y una cadena de dos llamadas queda
  # en ~14s, por debajo del límite global de 15s de Rack::Timeout (esa
  # excepción no se puede rescatar, a propósito).
  OPEN_TIMEOUT = 2
  REQUEST_TIMEOUT = 5

  private

  # Devuelve la Net::HTTPResponse, o nil si la URL es insegura/inválida o la
  # petición falló (timeout, conexión rechazada...).
  def evolution_request(url, api_key:, method: :get, query: {}, body: nil)
    full_url = query.present? ? "#{url}?#{query.to_query}" : url
    headers = { 'apikey' => api_key.to_s }
    headers['Content-Type'] = 'application/json' if body
    json_body = body&.to_json

    if allow_private_network?
      request_via_net_http(full_url, method, headers, json_body)
    else
      request_via_ssrf_filter(full_url, method, headers, json_body)
    end
  rescue SsrfFilter::Error, Resolv::ResolvError, URI::InvalidURIError => e
    Rails.logger.warn("Evolution API: unsafe or invalid URL (#{e.class})")
    nil
  rescue StandardError => e
    ChatwootExceptionTracker.new(e).capture_exception
    nil
  end

  def request_via_ssrf_filter(url, method, headers, json_body)
    http_options = { open_timeout: OPEN_TIMEOUT, read_timeout: REQUEST_TIMEOUT }

    case method
    when :post then SsrfFilter.post(url, headers: headers, body: json_body, http_options: http_options)
    when :delete then SsrfFilter.delete(url, headers: headers, http_options: http_options)
    else SsrfFilter.get(url, headers: headers, http_options: http_options)
    end
  end

  # Solo para desarrollo contra una instancia local de Evolution, que
  # SsrfFilter rechazaría por ser loopback. Nunca activar en producción.
  def request_via_net_http(url, method, headers, json_body)
    uri = URI.parse(url)
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = uri.scheme == 'https'
    # Sin esto quedaban los defaults de Net::HTTP (60s de read_timeout): una
    # Evolution local colgada bloqueaba la request hasta el Rack::Timeout.
    http.open_timeout = OPEN_TIMEOUT
    http.read_timeout = REQUEST_TIMEOUT
    request_class = { post: Net::HTTP::Post, delete: Net::HTTP::Delete }.fetch(method, Net::HTTP::Get)
    req = request_class.new(uri)
    headers.each { |key, value| req[key] = value }
    req.body = json_body if json_body
    http.request(req)
  end

  def allow_private_network?
    ENV.fetch('EVOLUTION_ALLOW_PRIVATE_NETWORK', 'false') == 'true'
  end

  def parse_json(response)
    return nil unless response.is_a?(Net::HTTPSuccess)

    JSON.parse(response.body)
  rescue JSON::ParserError
    nil
  end
end
