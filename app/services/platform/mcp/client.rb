require 'json'
require 'net/http'
require 'securerandom'

class Platform::Mcp::Client
  PROTOCOL_VERSION = '2024-11-05'.freeze
  CLIENT_NAME = 'Chatwoot'.freeze

  def initialize(server:)
    @server = server
    @session_id = nil
  end

  def initialize_session
    return true if @session_id.present?

    raise Platform::Mcp::Error, 'stdio transport is not supported yet' if @server.stdio?

    response = post_request(
      method: 'initialize',
      params: {
        protocolVersion: PROTOCOL_VERSION,
        capabilities: {
          tools: {},
          resources: {}
        },
        clientInfo: {
          name: CLIENT_NAME,
          version: ENV.fetch('APP_VERSION', 'dev')
        }
      }
    )

    post_notification('notifications/initialized')
    response.fetch('result', {})
  end

  def list_tools
    initialize_session
    post_request(method: 'tools/list').fetch('result', {}).fetch('tools', [])
  end

  def call_tool(tool_name:, arguments: {})
    initialize_session
    response = post_request(
      method: 'tools/call',
      params: {
        name: tool_name,
        arguments: arguments
      }
    )

    response.fetch('result', {})
  end

  private

  def post_request(method:, params: {})
    request_payload = {
      jsonrpc: '2.0',
      id: SecureRandom.uuid,
      method: method
    }
    request_payload[:params] = params if params.present?

    response = execute_http_request(request_payload)
    @session_id = response['Mcp-Session-Id'] || response['mcp-session-id'] || response['MCP-Session-Id'] || @session_id
    parsed = JSON.parse(response.body)

    raise Platform::Mcp::Error, parsed['error']['message'] if parsed['error'].present?

    parsed
  end

  def post_notification(method)
    request_payload = {
      jsonrpc: '2.0',
      method: method
    }

    execute_http_request(request_payload)
    true
  end

  def execute_http_request(payload)
    uri = URI.parse(@server.endpoint_url)
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = uri.scheme == 'https'
    http.open_timeout = @server.timeout_seconds
    http.read_timeout = @server.timeout_seconds

    request = Net::HTTP::Post.new(uri.request_uri)
    request['Content-Type'] = 'application/json'
    request['Mcp-Session-Id'] = @session_id if @session_id.present?
    request.body = payload.to_json
    apply_auth_headers(request)

    response = http.request(request)
    raise CustomExceptions::Platform::InvalidCredential.new(nil) if response.code.to_i == 401 || response.code.to_i == 403
    raise Platform::Mcp::Error, "MCP request failed with status #{response.code}" unless response.is_a?(Net::HTTPSuccess)

    response
  rescue JSON::ParserError => e
    raise Platform::Mcp::Error, "Invalid MCP response: #{e.message}"
  end

  def apply_auth_headers(request)
    credential = @server.platform_credential
    return if credential.blank?

    case credential.auth_type
    when 'bearer'
      token = credential.secret('token').presence || credential.secret('access_token').presence || credential.secret('api_key')
      request['Authorization'] = "Bearer #{token}" if token.present?
    when 'api_key'
      header_name = credential.metadata['header_name'].presence || credential.metadata[:header_name].presence || 'X-API-Key'
      api_key = credential.secret('api_key').presence || credential.secret('token').presence
      request[header_name] = api_key if api_key.present?
    when 'basic'
      username = credential.secret('username')
      password = credential.secret('password')
      request.basic_auth(username, password) if username.present? || password.present?
    when 'oauth2'
      token = credential.secret('access_token').presence || credential.secret('token')
      request['Authorization'] = "Bearer #{token}" if token.present?
    end
  end
end
