class Platform::Mcp::CallService
  # `client` lets a caller that makes several calls in a row (Captain's
  # McpTool during one agent turn) reuse an already-initialized session.
  def initialize(server:, tool_name:, arguments: {}, client: nil)
    @server = server
    @tool_name = tool_name
    @arguments = arguments
    @client = client
  end

  def call
    response = client.call_tool(tool_name: tool_name, arguments: arguments)
    record_usage('mcp.tools.call', status: 'success')
    normalize_result(response)
  rescue StandardError => e
    record_usage('mcp.tools.call', status: 'failed', error_code: e.class.name)
    raise
  end

  private

  attr_reader :server, :tool_name, :arguments

  def client
    @client ||= Platform::Mcp::Client.new(server: server)
  end

  def normalize_result(result)
    content = result['content'] || result[:content] || []
    Array(content).map do |entry|
      if entry.is_a?(Hash)
        entry['text'] || entry[:text] || entry['content'] || entry[:content] || entry.to_s
      else
        entry.to_s
      end
    end.join("\n").presence || result.to_s
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
      context: { server_id: server.id, tool_name: tool_name, transport_type: server.transport_type }
    )
  end
end
