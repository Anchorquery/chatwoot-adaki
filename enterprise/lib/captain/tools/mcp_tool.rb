require 'agents'

# One MCP tool exposed to the model.
#
# RubyLLM keeps `description` and the parameter schema on the CLASS, not the
# instance, so instantiating this class directly gave every MCP tool a nil
# description and an empty argument schema: the model saw a bare name and could
# never pass arguments. Each tool therefore gets its own anonymous subclass
# carrying its own description and schema — the same trick Concerns::Toolable
# already uses for custom HTTP tools.
#
# The MCP spec defines `inputSchema` as a JSON Schema object (type "object",
# properties, required), which is exactly what RubyLLM's `params` accepts as a
# raw Hash, so it is handed over verbatim rather than flattened into `param`
# declarations — that keeps enums, nested objects and item types intact.
# Providers reject JSON Schema keywords they do not implement (Gemini and
# `additionalProperties`/`$schema`/`pattern` is the classic case), but RubyLLM's
# Gemini adapter rebuilds the schema allow-list style, so the sanitising the
# ecosystem normally has to do by hand is already covered for us.
class Captain::Tools::McpTool < Agents::Tool
  # RubyLLM's Gemini adapter raises ArgumentError unless the tool schema is an
  # object, and McpServer#available_tool_metadata defaults input_schema to {}
  # for servers that advertise none — so an unusable schema is dropped rather
  # than allowed to break the whole agent build.
  SCHEMA_OBJECT_TYPE = 'object'.freeze

  # @return [Captain::Tools::McpTool] instance of a subclass carrying this
  #   tool's own description and argument schema.
  def self.build(assistant, server, tool_metadata)
    metadata = tool_metadata.with_indifferent_access
    tool_description = describe(metadata)
    schema = usable_schema(metadata[:input_schema])

    Class.new(self) do
      description tool_description
      params(schema) if schema
    end.new(assistant, server, metadata)
  end

  # MCP makes `description` optional. A synthesized one still tells the model
  # which server and remote tool it is reaching, which beats nil.
  def self.describe(metadata)
    metadata[:description].presence ||
      "Tool \"#{metadata[:tool_name]}\" provided by the #{metadata[:server_name]} MCP server."
  end

  def self.usable_schema(input_schema)
    return nil unless input_schema.is_a?(Hash)

    schema = input_schema.deep_stringify_keys
    return nil unless schema['type'].to_s == SCHEMA_OBJECT_TYPE

    schema
  end

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
    # The model has to decide what to do next (retry with different arguments,
    # ask the customer, hand off), and it cannot do that from "an error
    # occurred". The message stays short and carries no internals beyond the
    # remote error text.
    "The #{@tool_metadata[:tool_name]} tool failed: #{e.message}. " \
      'Do not retry it more than once; answer from what you already know or hand off to a human agent.'
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
