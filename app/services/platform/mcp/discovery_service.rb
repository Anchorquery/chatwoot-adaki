class Platform::Mcp::DiscoveryService
  def initialize(server:)
    @server = server
  end

  def call
    tools = client.list_tools.map { |tool| normalize_tool(tool) }
    record_usage('mcp.tools.list', status: 'success')
    tools
  rescue StandardError => e
    record_usage('mcp.tools.list', status: 'failed', error_code: e.class.name)
    raise
  end

  private

  attr_reader :server

  def client
    @client ||= Platform::Mcp::Client.new(server: server)
  end

  def normalize_tool(tool)
    {
      'name' => tool['name'] || tool[:name],
      'title' => tool['title'] || tool[:title] || (tool['name'] || tool[:name]).to_s.humanize,
      'description' => tool['description'] || tool[:description] || '',
      'inputSchema' => tool['inputSchema'] || tool[:inputSchema] || {}
    }
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
