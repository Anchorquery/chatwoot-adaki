class Captain::Tools::RegistryService
  def initialize(account:, assistant: nil)
    @account = account
    @assistant = assistant
  end

  def available_tool_metadata
    built_in_tools + custom_tool_metadata + mcp_tool_metadata
  end

  def available_tool_ids
    available_tool_metadata.map { |tool| tool[:id] }
  end

  def assistant_tools
    built_in_tool_instances + custom_tool_instances + mcp_tool_instances
  end

  def tool_instance(tool_id)
    metadata = available_tool_metadata.find { |tool| tool[:id] == tool_id }
    return nil if metadata.blank?

    build_tool_from_metadata(metadata)
  end

  def self.build_mcp_tool(assistant:, server:, tool_metadata:)
    Captain::Tools::McpTool.new(assistant, server, tool_metadata)
  end

  private

  attr_reader :account, :assistant

  def built_in_tools
    Captain::Assistant.built_in_agent_tools
  end

  def custom_tool_metadata
    account.captain_custom_tools.enabled.map { |tool| tool.to_tool_metadata.merge(type: 'custom') }
  end

  def mcp_tool_metadata
    account.captain_mcp_servers.enabled.flat_map(&:available_tool_metadata)
  end

  # Tools the orchestrator assistant itself can call. Until 2026-09-04 only
  # the first three were here and the housekeeping tools existed for
  # scenarios only, so a conversation the orchestrator handled directly could
  # never be labelled, prioritised, annotated or closed. `resolve_conversation`
  # is gated by the prompt (explicit customer confirmation only, never after a
  # handoff) and by the account-level auto-resolve switch the tool already
  # honours (Account#captain_auto_resolve_disabled?).
  def built_in_tool_instances
    [
      Captain::Tools::FaqLookupTool.new(assistant),
      Captain::Tools::SearchDocumentationTool.new(assistant),
      Captain::Tools::HandoffTool.new(assistant),
      Captain::Tools::AddLabelToConversationTool.new(assistant),
      Captain::Tools::UpdatePriorityTool.new(assistant),
      Captain::Tools::AddPrivateNoteTool.new(assistant),
      Captain::Tools::AddContactNoteTool.new(assistant),
      Captain::Tools::ResolveConversationTool.new(assistant)
    ]
  end

  def custom_tool_instances
    account.captain_custom_tools.enabled.filter_map { |tool| tool.tool(assistant) }
  end

  def mcp_tool_instances
    account.captain_mcp_servers.enabled.flat_map { |server| server.tool_instances(assistant) }
  end

  def build_tool_from_metadata(metadata)
    if metadata[:mcp]
      server = account.captain_mcp_servers.find_by(id: metadata[:server_id])
      return nil if server.blank?

      return Captain::Tools::McpTool.new(assistant, server, metadata)
    end

    if metadata[:custom]
      custom_tool = account.captain_custom_tools.enabled.find_by(slug: metadata[:id])
      return custom_tool&.tool(assistant)
    end

    class_name = "Captain::Tools::#{metadata[:id].classify}Tool"
    class_name.safe_constantize&.new(assistant)
  end
end
