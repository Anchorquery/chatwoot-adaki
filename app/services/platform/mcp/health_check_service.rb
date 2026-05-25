class Platform::Mcp::HealthCheckService
  def initialize(server:)
    @server = server
  end

  def call
    result = client.initialize_session
    record_usage('mcp.initialize', status: 'success')
    {
      ok: true,
      server_info: result['serverInfo'] || result[:serverInfo],
      protocol_version: result['protocolVersion'] || result[:protocolVersion]
    }
  rescue StandardError => e
    record_usage('mcp.initialize', status: 'failed', error_code: e.class.name)
    {
      ok: false,
      error: e.message
    }
  end

  private

  attr_reader :server

  def client
    @client ||= Platform::Mcp::Client.new(server: server)
  end

  def record_usage(operation, status:, error_code: nil)
    credential = server.platform_credential
    return if credential.blank?

    Platform::CredentialManager.record_use!(
      credential: credential,
      used_by: server,
      operation: operation,
      status: status,
      error_code: error_code,
      context: { server_id: server.id, transport_type: server.transport_type }
    )
  end
end
