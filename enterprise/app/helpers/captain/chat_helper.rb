module Captain::ChatHelper
  include Integrations::LlmInstrumentation
  include Captain::ChatResponseHelper
  include Captain::ChatGenerationRecorder

  def request_chat_completion
    with_llm_credential do |context|
      @llm_context = context
      log_chat_completion_request
      chat = build_chat

      add_messages_to_chat(chat)
      with_agent_session do
        last_content = conversation_messages.last[:content]
        text, attachments = Captain::OpenAiMessageBuilderService.extract_text_and_attachments(last_content)

        response = attachments.any? ? chat.ask(text, with: attachments) : chat.ask(text)
        build_response(response)
      end
    end
  rescue StandardError => e
    Rails.logger.error "#{self.class.name} Assistant: #{@assistant.id}, Error in chat completion: #{e}"
    raise e
  end

  private

  def build_chat
    llm_chat = chat(model: @model, temperature: temperature)
    json_params = json_response_params
    llm_chat = llm_chat.with_params(**json_params) if json_params.present?

    llm_chat = setup_tools(llm_chat)
    llm_chat = setup_system_instructions(llm_chat)
    setup_event_handlers(llm_chat)
  end

  # JSON-mode parameters differ per provider. OpenAI uses a top-level
  # `response_format`; Gemini expects `generationConfig.responseMimeType`.
  # Sending OpenAI's shape to Gemini makes the Google API reject the request,
  # so we pick the right shape based on the resolved credential's provider.
  def json_response_params
    case llm_request_provider
    when 'gemini'
      # Gemini rejects function calling combined with responseMimeType:
      # application/json. The assistant/copilot prompts already instruct JSON
      # output and parse_json_response strips fences + parses it, so when tools
      # are in play we drop the hint instead of breaking the request.
      return {} if @tools.present?

      { generationConfig: { responseMimeType: 'application/json' } }
    when 'openai'
      { response_format: { type: 'json_object' } }
    else
      # Unknown/other providers: skip the provider-specific JSON hint rather
      # than send an OpenAI-only param that could break the request.
      {}
    end
  end

  def llm_request_provider
    provider = nil
    provider ||= @resolved_credential.provider if @resolved_credential.respond_to?(:provider)
    provider ||= Llm::Models.models[@model]&.fetch('provider', nil) if defined?(Llm::Models)
    provider.to_s.presence || 'openai'
  end

  def setup_tools(llm_chat)
    @tools&.each do |tool|
      llm_chat = llm_chat.with_tool(tool)
    end
    llm_chat
  end

  def setup_system_instructions(chat)
    system_messages = @messages.select { |m| m[:role] == 'system' || m[:role] == :system }
    combined_instructions = system_messages.pluck(:content).join("\n\n")
    chat.with_instructions(combined_instructions)
  end

  def setup_event_handlers(chat)
    # NOTE: We only use on_end_message to record the generation with token counts.
    # RubyLLM callbacks fire after chunks arrive, not around the API call, so
    # span timing won't reflect actual API latency. But Langfuse calculates costs
    # from model + token counts, so this is sufficient for cost tracking.
    chat.on_end_message do |message|
      record_llm_generation(chat, message)
      accumulate_llm_usage(message)
    end
    chat.on_tool_call { |tool_call| handle_tool_call(tool_call) }
    chat.on_tool_result { |result| handle_tool_result(result) }
    chat
  end

  # Fires once per underlying LLM call — a tool-call round means chat.ask
  # drives multiple of these within a single #request_chat_completion, so
  # totals accumulate here rather than reading a single message's tokens.
  # Adaki::ChatHelperAdaki reads #llm_usage after `super` returns to record
  # real token counts instead of the parsed response hash it used to
  # introspect (which never carried usage data — see
  # docs/adaki/captain-remediacion.md §Fase 4, C10).
  def accumulate_llm_usage(message)
    @llm_usage ||= { input: 0, output: 0 }
    @llm_usage[:input] += message.input_tokens.to_i
    @llm_usage[:output] += message.respond_to?(:output_tokens) ? message.output_tokens.to_i : 0
  end

  def llm_usage
    @llm_usage || { input: 0, output: 0 }
  end

  def handle_tool_call(tool_call)
    persist_thinking_message(tool_call)
    start_tool_span(tool_call)
    (@pending_tool_calls ||= []).push(tool_call)
  end

  def handle_tool_result(result)
    end_tool_span(result)
    persist_tool_completion
  end

  def add_messages_to_chat(chat)
    conversation_messages[0...-1].each do |msg|
      text, attachments = Captain::OpenAiMessageBuilderService.extract_text_and_attachments(msg[:content])
      content = attachments.any? ? RubyLLM::Content.new(text, attachments) : text
      chat.add_message(role: msg[:role].to_sym, content: content)
    end
  end

  def instrumentation_params(chat = nil)
    {
      span_name: "llm.captain.#{feature_name}",
      account_id: resolved_account_id,
      conversation_id: @conversation_id,
      feature_name: feature_name,
      model: @model,
      messages: chat ? chat.messages.map { |m| { role: m.role.to_s, content: m.content.to_s } } : @messages,
      temperature: temperature,
      metadata: {
        assistant_id: @assistant&.id,
        channel_type: resolved_channel_type,
        source: @source
      }.compact
    }
  end

  def conversation_messages
    @messages.reject { |m| m[:role] == 'system' || m[:role] == :system }
  end

  def temperature
    @assistant&.config&.[]('temperature').to_f || 1
  end

  def resolved_account_id
    @account&.id || @assistant&.account_id
  end

  def resolved_channel_type
    @conversation&.inbox&.channel_type
  end

  # Ensures all LLM calls and tool executions within an agentic loop
  # are grouped under a single trace/session in Langfuse.
  #
  # Without this guard, each recursive call to request_chat_completion
  # (triggered by tool calls) would create a separate trace instead of
  # nesting within the existing session span.
  def with_agent_session(&)
    already_active = @agent_session_active
    return yield if already_active

    @agent_session_active = true
    instrument_agent_session(instrumentation_params, &)
  ensure
    @agent_session_active = false unless already_active
  end

  # Must be implemented by including class to identify the feature for instrumentation.
  # Used for Langfuse tagging and span naming.
  def feature_name
    raise NotImplementedError, "#{self.class.name} must implement #feature_name"
  end

  def log_chat_completion_request
    Rails.logger.info("#{self.class.name} Assistant: #{@assistant.id}, requesting completion for #{@messages} with #{@tools&.length || 0} tools")
  end

  # Yields the per-credential RubyLLM context resolved in Llm::BaseAiService#setup_model
  # (built from the account's enabled credential). request_chat_completion assigns it
  # to @llm_context so chat() routes to the configured provider's key/base. When nil
  # (legacy installs with no platform credential), chat() falls back to the global
  # RubyLLM config. Subclasses no longer need to override this.
  def with_llm_credential
    yield(@llm_context)
  end
end
