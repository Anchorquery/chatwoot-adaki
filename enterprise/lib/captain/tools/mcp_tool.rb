require 'agents'

class Captain::Tools::McpTool < Agents::Tool
  def initialize(assistant, server, tool_metadata)
    @assistant = assistant
    @server = server
    @tool_metadata = tool_metadata.with_indifferent_access

    super()
  end

  def active?
    @server.enabled?
  end

  def perform(_tool_context, **params)
    response = Platform::Mcp::CallService.new(
      server: @server,
      tool_name: @tool_metadata[:tool_name],
      arguments: params,
      client: mcp_client
    ).call

    response.to_s
  rescue StandardError => e
    Rails.logger.error("MCP tool execution error for #{@server.slug}/#{@tool_metadata[:tool_name]}: #{e.class} - #{e.message}")
    'An error occurred while executing the MCP tool'
  end

  def name
    @tool_metadata[:id]
  end

  private

  attr_reader :assistant, :server, :tool_metadata

  # A tool instance lives for one Captain turn (built by
  # AgentRunnerService#runner). Sharing the MCP client across its calls
  # keeps the session, so the initialize handshake (two HTTP round-trips)
  # happens once per turn instead of before every tool call.
  def mcp_client
    @mcp_client ||= Platform::Mcp::Client.new(server: @server)
  end
end
