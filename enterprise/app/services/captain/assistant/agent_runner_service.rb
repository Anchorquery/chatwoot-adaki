require 'agents'
require 'agents/instrumentation'

class Captain::Assistant::AgentRunnerService
  include Integrations::LlmInstrumentationConstants
  include Captain::Assistant::RunnerCallbacksHelper
  include Captain::Assistant::TracePayloadHelper

  CONVERSATION_STATE_ATTRIBUTES = %i[
    id display_id inbox_id contact_id status priority
    label_list custom_attributes additional_attributes
  ].freeze

  CONTACT_STATE_ATTRIBUTES = %i[
    id name email phone_number identifier contact_type
    custom_attributes additional_attributes
  ].freeze

  CONTACT_INBOX_STATE_ATTRIBUTES = %i[id hmac_verified].freeze

  CAMPAIGN_STATE_ATTRIBUTES = %i[id title message campaign_type description].freeze

  # Tools that are internal housekeeping (labels/notes/handoffs) rather than the
  # kind of lookup that actually answers the user's question. Calling one of
  # these does NOT count as "the agent did work this turn" for the promise-only
  # retry check below — everything else (search/FAQ/HTTP/MCP tools) does.
  HOUSEKEEPING_TOOL_NAMES = %w[
    add_label_to_conversation add_contact_note add_private_note
    update_priority resolve_conversation handoff
  ].freeze

  # Marks the internal nudge so a leaked echo in the retry's reply is
  # detectable and never forwarded to the customer (see usable_retry?).
  RETRY_NUDGE_MARKER = '[internal-completion-check]'.freeze
  RETRY_NUDGE = "#{RETRY_NUDGE_MARKER} You just replied with only a promise to look something up, without " \
                'calling any tool. Call the necessary tool right now and answer the user with the result in ' \
                'this same turn. Never mention this note, your previous reply, or that you were reminded — ' \
                'just give the final answer directly (or ask one short clarifying question if you genuinely ' \
                'cannot search yet).'.freeze

  PROMISE_ONLY_MAX_LENGTH = 240

  # Was 100 (10x the gem's own default/recommendation). Verified against the
  # installed ai-agents 0.10.0 source (lib/agents/runner.rb#run): current_turn
  # increments on every loop iteration, including tool-call continuations, not
  # just agent handoffs — so max_turns already bounds the full tool-call loop
  # on its own. 100 let a single Captain response chain up to 100 sequential
  # LLM/tool round-trips before giving up, a real contributor to multi-minute
  # hangs. See docs/adaki/captain-remediacion.md §3.
  MAX_TURNS = 10

  DEFAULT_USAGE = { input: 0, output: 0 }.freeze

  # Patterns for "let me check/search and get back to you" replies with no tool
  # call behind them, across the languages Captain commonly runs in. Kept as a
  # plain Ruby constant (not prompt text) so it's testable and provider-agnostic.
  PROMISE_ONLY_PATTERNS = [
    /\b(let|give)\s+me\s+(a\s+)?(moment|second|minute)\b/i,
    /\blet\s+me\s+(check|look|search|find|verify|see)\b/i,
    /\bi(?:'ll| will)\s+(check|look|search|find|verify)\b/i,
    /\b(un|dame un)\s+moment(o|ito)?\b/i,
    /\b(d[ée]jame|permíteme|permiteme)\s+(revisar|buscar|verificar|consultar|checar)\b/i,
    /\bvoy\s+a\s+(revisar|buscar|verificar|consultar)\b/i,
    /\b(vou|deixa[- ]?me)\s+(verificar|checar|procurar|olhar)\b/i,
    /\bje\s+vais\s+(v[ée]rifier|chercher|regarder)\b/i,
    /\blaisse[- ]moi\s+(v[ée]rifier|chercher)\b/i
  ].freeze

  def initialize(assistant:, conversation: nil, callbacks: {}, source: nil)
    @assistant = assistant
    @conversation = conversation
    @callbacks = callbacks
    @source = source
    @handoff_tool_called = false
  end

  def generate_response(message_history: [])
    message_to_process, context = run_payload(message_history)
    # The ai-agents gem builds its chats from the global RubyLLM config and
    # validates the credential eagerly in Chat.new. Publish the account's
    # resolved credential as the per-thread context so those chats route to the
    # configured provider (e.g. Gemini) instead of always hitting OpenAI.
    result = RubyLLM.with_thread_context(resolved_llm_context) do
      runner.run(message_to_process, context: context, max_turns: MAX_TURNS)
    end
    result = retry_if_promise_only(result)
    record_adaki_usage!(result)

    process_agent_result(result)
  rescue StandardError => e
    # In rake/local runs, conversation may not be present, so account is optional here.
    ChatwootExceptionTracker.new(e, account: @conversation&.account).capture_exception
    Rails.logger.error "[Captain V2] AgentRunnerService error: #{e.message}"
    Rails.logger.error e.backtrace.join("\n")

    error_response(e)
  end

  private

  def build_context(message_history)
    conversation_history = message_history.map do |msg|
      content = msg[:content]
      # Preserve multimodal arrays (with image_url entries) as-is for the runner to restore with attachments.
      # Only extract text from non-array formats (hashes from agent structured output, plain strings).
      content = extract_text_from_content(content) unless content.is_a?(Array)

      {
        role: msg[:role].to_sym,
        content: content,
        agent_name: msg[:agent_name]
      }
    end

    {
      session_id: "#{@assistant.account_id}_#{@conversation&.display_id}",
      conversation_history: conversation_history,
      state: build_state
    }
  end

  def extract_last_user_message(message_history)
    last_user_msg = message_history.reverse.find { |msg| msg[:role] == 'user' }
    return '' if last_user_msg.blank?

    content = last_user_msg[:content]
    return extract_text_from_content(content) unless content.is_a?(Array)

    text, attachments = Captain::OpenAiMessageBuilderService.extract_text_and_attachments(content)
    return text if attachments.blank?

    RubyLLM::Content.new(text, attachments)
  end

  def message_history_without_last_user_message(message_history)
    last_user_index = message_history.rindex { |msg| msg[:role] == 'user' }
    return message_history if last_user_index.nil?

    message_history.reject.with_index { |_msg, index| index == last_user_index }
  end

  def extract_text_from_content(content)
    # Handle structured output from agents
    return content[:response] || content['response'] || content.to_s if content.is_a?(Hash)

    return content unless content.is_a?(Array)

    text_parts = content.select { |part| part[:type] == 'text' }.pluck(:text)
    text_parts.join(' ')
  end

  # The LLM sometimes ends its turn with only a promise to look something up
  # ("let me check that", "déjame buscar") without ever calling a tool, leaving
  # the customer waiting for a reply that never comes. When that happens (no
  # content tool ran, no handoff happened) we replay the run once with an
  # internal nudge. The nudge text and this extra turn live only inside this
  # in-memory retry: conversation_history is rebuilt from Chatwoot's persisted
  # messages on every call, so nothing here is ever written back or reused on
  # a future turn. If the retry doesn't clearly improve on the original
  # (still a promise, blank, or echoes the nudge), the original reply is kept
  # as-is — this can only add a second attempt, never make things worse.
  def retry_if_promise_only(result)
    return result unless promise_only_result?(result)

    Rails.logger.info '[Captain V2] Promise-only reply with no tool call detected, retrying once'

    retry_result = RubyLLM.with_thread_context(resolved_llm_context) do
      runner.run(RETRY_NUDGE, context: result.context, max_turns: MAX_TURNS)
    end

    usable_retry?(retry_result) ? retry_result : result
  end

  def promise_only_result?(result)
    return false if result_errored?(result)
    return false if result.context&.dig(:captain_v2_handoff_tool_called)
    return false if content_tool_called?(result)

    promise_only_text?(response_text(result.output))
  end

  def usable_retry?(result)
    return false if result_errored?(result)

    text = response_text(result.output)
    return false if text.blank?
    return false if text.include?(RETRY_NUDGE_MARKER)

    !promise_only_text?(text)
  end

  def result_errored?(result)
    result.respond_to?(:error) && result.error.present?
  end

  def content_tool_called?(result)
    (result.context&.dig(:captain_v2_content_tool_calls) || 0).positive?
  end

  def response_text(output)
    output.is_a?(Hash) ? (output['response'] || output[:response]).to_s : output.to_s
  end

  def promise_only_text?(text)
    text = text.to_s.strip
    return false if text.blank? || text.length > PROMISE_ONLY_MAX_LENGTH || text.end_with?('?')

    PROMISE_ONLY_PATTERNS.any? { |pattern| text.match?(pattern) }
  end

  def process_agent_result(result)
    Rails.logger.info "[Captain V2] Agent result: #{result.inspect}"

    # The ai-agents runner swallows exceptions into result.error and returns a
    # nil output, which would otherwise surface as an empty reply. Surface a
    # clear, actionable message instead (mirrors make_api_call's api_key_missing
    # in the BaseTaskService flow that already works for Gemini).
    return llm_error_response(result.error) if result.respond_to?(:error) && result.error.present?

    output = result.output
    response = output.is_a?(Hash) ? output.with_indifferent_access : { 'response' => output.to_s, 'reasoning' => 'Processed by agent' }
    response['agent_name'] = result.context&.dig(:current_agent)
    response['handoff_tool_called'] = result.context&.dig(:captain_v2_handoff_tool_called) || false
    suppress_handoff_announcement_leak!(response)
    response
  end

  # The prompt tells the LLM twice never to announce a transfer, but it can
  # still hallucinate one — narrate "you've been transferred" in its reply
  # text without ever calling HandoffTool (observed in production, conv 120).
  # response['handoff_tool_called'] is the real "receipt": if it's false, no
  # transfer actually happened, so a reply claiming otherwise is an
  # unsupported claim, not a legitimate handoff message (which already goes
  # through the clean create_handoff_message template in
  # ResponseBuilderJob#process_v2_handoff and never reaches this path). This
  # is the same fabricated-tool-call class of failure other LLM agent
  # platforms hit (e.g. voice agents announcing a call transfer that never
  # fires) — see docs/adaki/captain-remediacion.md §Fase 4 (C12).
  #
  # Verb forms matter: the first production leak was "Se ha transferido…",
  # the second one (conversation 120, 2026-09-04) was "Te transfiero con un
  # agente humano…", which the original /transferid[oa]/ never matched.
  HANDOFF_ANNOUNCEMENT_LEAK_PATTERN = /
    transferid[oa] | transferred | transferring |
    te\s+(transfiero|transferir[eé]|paso|pasar[eé]|conecto|conectar[eé]|comunico|derivo|remito)\s+(con|a)\b |
    te\s+voy\s+a\s+(transferir|pasar|conectar|derivar|comunicar) |
    (transferir|pasar|conectar|derivar)(te|le|lo)\s+(con|a)\b |
    (te|le)\s+pongo\s+en\s+contacto |
    hablar[áa]s\s+con\s+(un|otro)
  /ix

  def suppress_handoff_announcement_leak!(response)
    return if response['handoff_tool_called']

    text = response['response'].to_s
    return unless text.match?(HANDOFF_ANNOUNCEMENT_LEAK_PATTERN)

    Rails.logger.warn(
      '[Captain V2] Suppressed a reply that falsely claimed a handoff happened (no handoff tool was ' \
      "called) for assistant=#{@assistant&.id} conversation=#{@conversation&.display_id}"
    )
    response['response'] = I18n.t('conversations.captain.handoff_announcement_leak_fallback')
    response['reasoning'] = 'Suppressed a hallucinated handoff announcement (no handoff tool was called)'
  end

  def llm_error_response(error)
    Rails.logger.error "[Captain V2] LLM error: #{error.class}: #{error.message}"

    reasoning = if error.is_a?(RubyLLM::ConfigurationError)
                  'El proveedor de IA de esta cuenta no está configurado correctamente ' \
                    '(falta la API key o la credencial del proveedor). Revisa los modelos/credenciales de Captain. ' \
                    "Detalle: #{error.message}"
                else
                  "Error del proveedor de IA: #{error.message}"
                end

    {
      'response' => 'conversation_handoff',
      'reasoning' => reasoning,
      'error' => error.message,
      # See Captain::FailurePolicy — lets ResponseBuilderJob tell a dead
      # credential apart from a transient provider hiccup (which should be
      # retried, not handed off) even though the exception object itself
      # never reaches the job in the V2 path.
      'failure_class' => Captain::FailurePolicy.classify(error).to_s,
      'handoff_tool_called' => @handoff_tool_called
    }
  end

  def error_response(error)
    {
      'response' => 'conversation_handoff',
      'reasoning' => "Error occurred: #{error.message}",
      'error' => error.message,
      'failure_class' => Captain::FailurePolicy.classify(error).to_s,
      'handoff_tool_called' => @handoff_tool_called
    }
  end

  def build_state
    state = {
      account_id: @assistant.account_id,
      assistant_id: @assistant.id,
      assistant_config: @assistant.config
    }
    state[:source] = @source if @source.present?

    build_conversation_state(state) if @conversation
    state
  end

  def build_conversation_state(state)
    state[:conversation] = slice_attrs(@conversation, CONVERSATION_STATE_ATTRIBUTES)
    state[:channel_type] = @conversation.inbox&.channel_type
    state[:contact] = slice_attrs(@conversation.contact, CONTACT_STATE_ATTRIBUTES) if @conversation.contact
    state[:campaign] = slice_attrs(@conversation.campaign, CAMPAIGN_STATE_ATTRIBUTES) if @conversation.campaign
    state[:contact_inbox] = slice_attrs(@conversation.contact_inbox, CONTACT_INBOX_STATE_ATTRIBUTES) if @conversation.contact_inbox
  end

  def slice_attrs(record, keys)
    record.attributes.symbolize_keys.slice(*keys)
  end

  def build_and_wire_agents
    assistant_agent = @assistant.agent
    scenario_agents = @assistant.scenarios.enabled.map(&:agent)

    assistant_agent.register_handoffs(*scenario_agents) if scenario_agents.any?
    scenario_agents.each { |scenario_agent| scenario_agent.register_handoffs(assistant_agent) }

    [assistant_agent] + scenario_agents
  end

  def install_instrumentation(runner)
    return unless ChatwootApp.otel_enabled?

    Agents::Instrumentation.install(
      runner,
      tracer: OpentelemetryConfig.tracer,
      trace_name: 'llm.captain_v2',
      span_attributes: {
        ATTR_LANGFUSE_TAGS => ['captain_v2'].to_json
      },
      attribute_provider: ->(context_wrapper) { dynamic_trace_attributes(context_wrapper) }
    )
    register_trace_input_callback(runner)
  end

  def dynamic_trace_attributes(context_wrapper)
    state = context_wrapper&.context&.dig(:state) || {}
    conversation = state[:conversation] || {}
    trace_input = context_wrapper&.context&.dig(:captain_v2_trace_input)

    {
      ATTR_LANGFUSE_USER_ID => state[:account_id],
      format(ATTR_LANGFUSE_METADATA, 'assistant_id') => state[:assistant_id],
      format(ATTR_LANGFUSE_METADATA, 'conversation_id') => conversation[:id],
      format(ATTR_LANGFUSE_METADATA, 'conversation_display_id') => conversation[:display_id],
      format(ATTR_LANGFUSE_METADATA, 'channel_type') => state[:channel_type],
      format(ATTR_LANGFUSE_METADATA, 'source') => state[:source],
      ATTR_LANGFUSE_TRACE_INPUT => trace_input,
      ATTR_LANGFUSE_OBSERVATION_INPUT => trace_input
    }.compact.transform_values(&:to_s)
  end

  def add_usage_metadata_callback(runner)
    handoff_tool_name = Captain::Tools::HandoffTool.new(@assistant).name

    # Tool tracking always runs — process_response in the job consumes the resulting
    # handoff_tool_called flag regardless of whether OTEL is enabled.
    runner.on_tool_complete do |tool_name, _tool_result, context_wrapper|
      track_handoff_usage(tool_name, handoff_tool_name, context_wrapper)
      track_content_tool_usage(tool_name, context_wrapper)
    end

    if ChatwootApp.otel_enabled?
      runner.on_run_complete do |_agent_name, _result, context_wrapper|
        write_credits_used_metadata(context_wrapper)
      end
    end
    runner
  end

  # Unlike V1 (Captain::ChatHelperAdaki), V2 never went through anything that
  # called Adaki::CaptainUsageTracker — every V2 response was invisible to
  # Adaki's usage dashboard and audit log. on_chat_created fires once per
  # RubyLLM::Chat the runner creates (including after a handoff to a
  # scenario agent); registering on_end_message inside it, same as V1, is
  # what actually sums real tokens across every LLM call the response made
  # (result.usage undercounts — see docs/adaki/captain-remediacion.md §Fase
  # 4, C10). Deliberately tracking only, not enforcing: wiring
  # enforce_limit! here would newly start blocking accounts that are
  # currently silently unlimited on V2, which needs an explicit decision,
  # not a side effect of fixing the accounting gap.
  def add_usage_tracking_callback(runner)
    runner.on_chat_created do |chat, _agent_name, _model, context_wrapper|
      chat.on_end_message { |message| accumulate_usage(context_wrapper, message) }
    end
    runner
  end

  def accumulate_usage(context_wrapper, message)
    return unless context_wrapper&.context

    usage = (context_wrapper.context[:captain_v2_usage] ||= { input: 0, output: 0 })
    usage[:input] += message.input_tokens.to_i
    usage[:output] += message.respond_to?(:output_tokens) ? message.output_tokens.to_i : 0
  end

  def record_adaki_usage!(result)
    usage = result.context&.dig(:captain_v2_usage) || DEFAULT_USAGE
    Adaki::CaptainUsageTracker.record!(
      account: adaki_account,
      feature: 'assistant',
      input_tokens: usage[:input],
      output_tokens: usage[:output],
      assistant_id: @assistant&.id
    )
  end

  def adaki_account
    @conversation&.account || @assistant&.account
  end

  def track_handoff_usage(tool_name, handoff_tool_name, context_wrapper)
    return unless context_wrapper&.context
    return unless tool_name.to_s == handoff_tool_name

    # Mirror the flag onto the instance so error_response can surface it even when
    # the runner raises before returning a result (the context is unreachable then).
    context_wrapper.context[:captain_v2_handoff_tool_called] = true
    @handoff_tool_called = true
  end

  # Counts tool calls that actually do the work of answering the user (search,
  # FAQ lookup, HTTP/MCP tools) as opposed to silent housekeeping (labels,
  # notes, handoffs). Feeds promise_only_result? above.
  def track_content_tool_usage(tool_name, context_wrapper)
    return unless context_wrapper&.context

    name = tool_name.to_s
    return if name.start_with?('handoff_to_') || HOUSEKEEPING_TOOL_NAMES.include?(name)

    context_wrapper.context[:captain_v2_content_tool_calls] = (context_wrapper.context[:captain_v2_content_tool_calls] || 0) + 1
  end

  def write_credits_used_metadata(context_wrapper)
    root_span = context_wrapper&.context&.dig(:__otel_tracing, :root_span)
    return unless root_span

    root_span.set_attribute(format(ATTR_LANGFUSE_METADATA, 'credit_used'), @handoff_tool_called ? 'false' : 'true')
  end

  def runner
    @runner ||= begin
      configured_runner = Agents::Runner.with_agents(*build_and_wire_agents)
      configured_runner = add_usage_metadata_callback(configured_runner)
      configured_runner = add_usage_tracking_callback(configured_runner)
      configured_runner = add_callbacks_to_runner(configured_runner) if @callbacks.any?
      install_instrumentation(configured_runner)
      configured_runner
    end
  end

  # RubyLLM context carrying the account's resolved credential (provider + key +
  # api_base). Published as the per-thread default around the runner execution so
  # the ai-agents chats route to the configured provider. Nil when the account
  # has no platform credential, in which case the runner keeps using the global
  # RubyLLM config (legacy installs).
  def resolved_llm_context
    return @resolved_llm_context if defined?(@resolved_llm_context)

    account = @assistant&.account
    resolved = account && Platform::Models::Resolver.resolve(account: account, feature: 'assistant')
    @resolved_llm_context = Llm::Config.context_for_credential(resolved&.dig(:credential))
  end

  def run_payload(message_history)
    message_to_process = extract_last_user_message(message_history)
    context = build_context(message_history_without_last_user_message(message_history))
    enrich_context_with_trace_payload!(context, message_history, message_to_process)
    [message_to_process, context]
  end
end
