require 'agents'

class Captain::Llm::AssistantChatService < Llm::BaseAiService
  include Captain::ChatHelper

  def initialize(assistant: nil, conversation: nil, source: nil)
    super()

    @assistant = assistant
    @conversation = conversation
    @conversation_id = conversation&.display_id
    @source = source

    # Re-resolve model now that @assistant (and therefore the account) is set,
    # so Platform::Models::Resolver can honor the credential/model toggles.
    setup_model

    @messages = [system_message]
    @response = ''
    @tools = build_tools
  end

  # additional_message: A single message (String) from the user that should be appended to the chat.
  #                    It can be an empty String or nil when you only want to supply historical messages.
  # message_history:   An Array of already formatted messages that provide the previous context.
  # role:              The role for the additional_message (defaults to `user`).
  #
  # NOTE: Parameters are provided as keyword arguments to improve clarity and avoid relying on
  # positional ordering.
  def generate_response(additional_message: nil, message_history: [], role: 'user')
    @messages += message_history
    @messages << { role: role, content: additional_message } if additional_message.present?
    request_chat_completion
  end

  private

  def build_tools
    tools = [Captain::Tools::SearchDocumentationService.new(@assistant, user: nil)]
    registry_tools = Captain::Tools::RegistryService.new(account: @assistant.account, assistant: @assistant).assistant_tools
    tools + v1_compatible_tools(registry_tools)
  end

  # Captain::Tools::BasePublicTool (FaqLookupTool, HandoffTool, add_label_to_
  # conversation, etc.) and Captain::Tools::McpTool all inherit from
  # Agents::Tool, whose #execute(tool_context, **params) takes a required
  # positional tool_context. V1's plain RubyLLM::Chat has no such context to
  # pass — RubyLLM::Tool#call invokes execute(**args) with no positional
  # argument at all, so the instant the LLM calls one of these tools it
  # raises ArgumentError, which V1 has no recovery for beyond a plain
  # handoff. Every V1 conversation that reaches a tool call was hitting this.
  # V1 already has its own tool-independent handoff signal
  # (Captain::Llm::AssistantActionClassifierService reads the reply text, no
  # tool call needed), so dropping these here loses nothing V1 could
  # actually use — it trades a crash-triggered false handoff for the tool
  # simply not being offered. See docs/adaki/captain-remediacion.md §Fase 4
  # (C5).
  def v1_compatible_tools(tools)
    tools.reject { |tool| tool.is_a?(Agents::Tool) }
  end

  def system_message
    {
      role: 'system',
      content: Captain::Llm::SystemPromptsService.assistant_response_generator(
        @assistant.name, @assistant.config['product_name'], @assistant.config.merge('timezone' => inbox_timezone),
        contact: contact_attributes,
        custom_tools: custom_tools_metadata
      )
    }
  end

  # available_tool_metadata's mcp/custom entries describe exactly the tools
  # v1_compatible_tools filters out above (both are Agents::Tool-based) — so
  # for V1 this can never have anything real to list. Advertising them here
  # anyway would have the system prompt tell the LLM about tools it then
  # can't actually call (they're absent from the RubyLLM function-calling
  # schema chat.with_tool builds), which invites a hallucinated "I'll use
  # tool X" reply instead of a clean unsupported-tool omission.
  def custom_tools_metadata
    []
  end

  def contact_attributes
    return nil unless @conversation&.contact
    return nil unless @assistant&.feature_contact_attributes

    @conversation.contact.attributes.symbolize_keys.slice(
      :id, :name, :email, :phone_number, :identifier, :custom_attributes
    )
  end

  def inbox_timezone
    @conversation&.inbox&.timezone.presence || 'UTC'
  end

  def resolver_account
    @assistant&.account
  end

  def feature_key
    feature_name
  end

  def persist_message(message, message_type = 'assistant')
    # No need to implement
  end

  def feature_name
    'assistant'
  end
end
