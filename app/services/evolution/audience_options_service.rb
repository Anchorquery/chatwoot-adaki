class Evolution::AudienceOptionsService
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

    response = HTTParty.get(
      "#{base_url}/instance/connectionState/#{encoded_instance_name}",
      headers: { 'apikey' => api_key },
      timeout: 10
    )
    { success: response.success?, message: response.success? ? 'ok' : "http_#{response.code}" }
  rescue StandardError => e
    ChatwootExceptionTracker.new(e).capture_exception
    { success: false, message: 'connection_error' }
  end

  private

  def fetch(path, query = {})
    return [] unless configured?

    response = HTTParty.get(
      "#{base_url}/#{path}/#{encoded_instance_name}",
      headers: { 'apikey' => api_key },
      query: query,
      timeout: 10
    )
    return [] unless response.success?

    Array.wrap(response.parsed_response)
  rescue StandardError => e
    ChatwootExceptionTracker.new(e).capture_exception
    []
  end

  def configured?
    base_url.present? && api_key.present? && instance_name.present?
  end

  # Evolution ya arma el webhook_url del inbox como
  # "{base_url}/chatwoot/webhook/{instanceName}" al conectar el canal
  # (ver initInstanceChatwoot en chatwoot.service.ts de Evolution). En vez
  # de pedirle a Evolution URL/nombre de instancia de nuevo, los sacamos
  # de ahí — solo la apikey no tiene forma de derivarse.
  def parsed_webhook_uri
    return @parsed_webhook_uri if defined?(@parsed_webhook_uri)

    @parsed_webhook_uri = URI.parse(@webhook_url) if @webhook_url.present?
  rescue URI::InvalidURIError
    @parsed_webhook_uri = nil
  end

  def base_url
    uri = parsed_webhook_uri
    return nil unless uri&.host

    port_suffix = uri.port && [80, 443].exclude?(uri.port) ? ":#{uri.port}" : ''
    "#{uri.scheme}://#{uri.host}#{port_suffix}"
  end

  def instance_name
    uri = parsed_webhook_uri
    return nil unless uri&.path

    segment = uri.path.split('/').last
    segment.present? ? CGI.unescape(segment) : nil
  end

  # El nombre puede traer espacios u otros caracteres (ej. "EAJ - PNV");
  # hay que re-codificarlo al armar URLs hacia Evolution.
  def encoded_instance_name
    ERB::Util.url_encode(instance_name)
  end

  def api_key
    @config['evolution_api_key']
  end
end
