class Captain::Conversation::ResponseBuilderJob < ApplicationJob
  include Captain::Conversation::V1ActionClassifier

  # Dedicated Sidekiq capsule (config/initializers/sidekiq.rb) — an LLM
  # provider incident stays isolated to Captain traffic instead of starving
  # the shared :default queue of worker threads.
  queue_as :captain

  retry_on ActiveStorage::FileNotFoundError, attempts: 3, wait: 2.seconds
  retry_on Faraday::BadRequestError, attempts: 3, wait: 2.seconds
  # See Captain::FailurePolicy: a provider hiccup (rate limit, 5xx, dropped
  # connection) should be retried, never handed off. RubyLLM/Faraday already
  # ran their own short internal retry before this reaches us — this is a
  # second, coarser layer with real backoff instead of hammering a struggling
  # provider again within milliseconds.
  retry_on Captain::FailurePolicy::TransientProviderError, wait: :polynomially_longer, attempts: 3

  def perform(conversation, assistant)
    @conversation = conversation
    @inbox = conversation.inbox
    @assistant = assistant

    return unless conversation_captain_controllable?

    Current.executed_by = @assistant

    dispatch_response
  rescue ActiveStorage::FileNotFoundError, Faraday::BadRequestError => e
    handle_error(e)
    raise e
  rescue StandardError => e
    handle_error(e)
  ensure
    Current.executed_by = nil
  end

  private

  delegate :account, :inbox, to: :@conversation

  def dispatch_response
    if Captain::CredentialCircuitBreaker.open?(account)
      handle_open_circuit
    elsif !usable_credential_configured?
      handle_missing_credential
    elsif captain_v2_enabled?
      generate_response_with_v2
    else
      generate_and_process_response
    end
  end

  # See Captain::CredentialCircuitBreaker: skip the doomed LLM attempt
  # entirely once this account's credential has recently failed repeatedly
  # with a configuration error — otherwise every incoming message pays for a
  # call we already know will fail, and spams a fresh diagnostic note each
  # time. Routes through the normal handoff pipeline so the customer still
  # gets a handoff and FailureNotifier still leaves a note.
  def handle_open_circuit
    Rails.logger.info("[CAPTAIN][ResponseBuilderJob] Circuit open for account=#{account.id}, skipping LLM call")
    @response = {
      'response' => 'conversation_handoff',
      'action_source' => 'circuit_breaker',
      'action_reason' => 'credential_circuit_open',
      'failure_class' => Captain::FailurePolicy::CONFIGURATION.to_s,
      'error' => 'El proveedor de IA de esta cuenta viene fallando repetidamente. ' \
                 'Revisa la credencial en Configuración → Captain.'
    }
    process_response
  end

  # An account with no Platform::Credential of its own used to silently ride
  # on the shared global RubyLLM config (InstallationConfig's own API keys)
  # forever, with no visibility into which accounts were actually depending
  # on someone else's key. Llm::Config.global_fallback_allowed? defaults to
  # true (nothing changes until an operator opts in), but once turned off,
  # an account with no credential of its own gets a clear, diagnosable
  # handoff instead of an invisible dependency on shared usage/limits. See
  # docs/adaki/captain-remediacion.md §Fase 2c.
  def usable_credential_configured?
    return true if Llm::Config.global_fallback_allowed?

    Platform::Models::Resolver.resolve(account: account, feature: 'assistant').present?
  end

  def handle_missing_credential
    Rails.logger.info("[CAPTAIN][ResponseBuilderJob] No credential configured for account=#{account.id}, skipping LLM call")
    @response = {
      'response' => 'conversation_handoff',
      'action_source' => 'missing_credential',
      'action_reason' => 'no_credential_configured',
      'failure_class' => Captain::FailurePolicy::CONFIGURATION.to_s,
      'error' => 'Esta cuenta no tiene un proveedor de IA configurado. ' \
                 'Configura una credencial en Configuración → Captain.'
    }
    process_response
  end

  def generate_and_process_response
    message_history = collect_previous_messages
    @response = Captain::Llm::AssistantChatService.new(assistant: @assistant, conversation: @conversation).generate_response(
      message_history: message_history
    )
    classify_v1_response_action(message_history) if conversation_captain_controllable?
    process_response
  end

  def generate_response_with_v2
    @response = Captain::Assistant::AgentRunnerService.new(assistant: @assistant, conversation: @conversation).generate_response(
      message_history: collect_previous_messages
    )
    # The V2 runner swallows LLM errors into a handoff-token response instead of
    # raising (see AgentRunnerService#llm_error_response/#error_response), so a
    # transient provider failure never reaches this job's own rescue/handle_error
    # on its own. Re-raise it here instead of handing off — see Captain::FailurePolicy.
    raise Captain::FailurePolicy::TransientProviderError, @response['error'] if transient_v2_failure?

    Captain::CredentialCircuitBreaker.record_failure!(account) if configuration_failure?

    process_response
  end

  def process_response
    track_credential_health!

    # Check V2 before V1: error_response can set both signals at once when HandoffTool
    # fired before the runner errored. V2 must win — running V1 on top would duplicate
    # OOO and re-dispatch the bot_handoff event.
    if v2_handoff_tool_fired?
      if conversation_pending?
        # HandoffTool flipped the flag without committing — its perform returned a
        # failure string (e.g. "Conversation not found") before bot_handoff! ran. Fall
        # back to a full V1 handoff so the customer still ends up with a human.
        process_v1_handoff
      else
        # HandoffTool already opened the conversation inside the agent loop. All that's
        # left is the customer-facing follow-up message.
        process_v2_handoff
      end
    elsif v1_handoff_requested?
      # V1 only signals via the response string — no state has been touched yet. If
      # the conversation isn't pending anymore, a human took over mid-run; bail out
      # rather than posting a stale handoff message on top of their reply.
      return unless conversation_pending?

      process_v1_handoff
    elsif conversation_captain_controllable?
      ActiveRecord::Base.transaction do
        create_messages
        Rails.logger.info("[CAPTAIN][ResponseBuilderJob] Incrementing response usage for #{account.id}")
        account.increment_response_usage
      end
    end
  end

  # See Captain::Conversation::HistoryBuilder for the message-shaping rules
  # (history window, per-message truncation, human-vs-bot role attribution).
  def collect_previous_messages
    Captain::Conversation::HistoryBuilder.new(conversation: @conversation, assistant: @assistant).call
  end

  def v1_handoff_requested?
    legacy_v1_handoff_token? || classifier_v1_handoff_requested?
  end

  def classifier_v1_handoff_requested?
    @response['action'] == 'handoff'
  end

  def legacy_v1_handoff_token?
    @response['response'] == 'conversation_handoff'
  end

  def v2_handoff_tool_fired?
    @response['handoff_tool_called'] == true
  end

  # A credential that just worked (or failed for a reason unrelated to the
  # credential itself — budget/limit_adaki/unknown) resets the circuit
  # breaker's failure count. Skipped specifically for 'configuration' so this
  # doesn't immediately undo the record_failure! a caller
  # (generate_response_with_v2 above, or handle_error below) just made
  # moments ago.
  def track_credential_health!
    return if configuration_failure?

    Captain::CredentialCircuitBreaker.record_success!(account)
  end

  def transient_v2_failure?
    failure_class?(Captain::FailurePolicy::TRANSIENT)
  end

  def configuration_failure?
    failure_class?(Captain::FailurePolicy::CONFIGURATION)
  end

  def failure_class?(classification)
    @response['failure_class'] == classification.to_s
  end

  def process_v1_handoff
    I18n.with_locale(@assistant.account.locale) do
      Rails.logger.info(
        "[CAPTAIN][ResponseBuilderJob] V1 handoff requested for account=#{account.id} conversation=#{@conversation.display_id} " \
        "source=#{@response&.dig('action_source') || 'legacy'} reason=#{@response&.dig('action_reason')}"
      )
      create_handoff_message
      @conversation.bot_handoff!
      # See Captain::Conversation::FailureNotifier: only writes a note when the
      # handoff was actually caused by a diagnosable infrastructure failure
      # (dead credential, exhausted quota), not a legitimate escalation. After
      # bot_handoff! on purpose: the note @mentions whoever the handoff just
      # assigned (or the handoff team), so they get notified with the cause.
      Captain::Conversation::FailureNotifier.new(conversation: @conversation, assistant: @assistant, response: @response).call
      report_v1_handoff_not_executed if conversation_pending?
      send_out_of_office_message_if_applicable
    end
  end

  def process_v2_handoff
    # HandoffTool already ran bot_handoff! + OOO inside the agent loop. Preserve
    # waiting_since so this message doesn't clear the timestamp it left in place.
    I18n.with_locale(@assistant.account.locale) do
      create_handoff_message(preserve_waiting_since: true)
    end
  end

  def send_out_of_office_message_if_applicable
    # Campaign conversations should never receive OOO templates — the campaign itself
    # serves as the initial outreach, and OOO would be confusing in that context.
    return if @conversation.campaign.present?

    ::MessageTemplates::Template::OutOfOffice.perform_if_applicable(@conversation)
  end

  def create_handoff_message(preserve_waiting_since: false)
    create_outgoing_message(
      @assistant.config['handoff_message'].presence || I18n.t('conversations.captain.handoff'),
      preserve_waiting_since: preserve_waiting_since
    )
  end

  def create_messages
    validate_message_content!(@response['response'])
    create_outgoing_message(@response['response'], agent_name: @response['agent_name'])
  end

  def validate_message_content!(content)
    raise ArgumentError, 'Message content cannot be blank' if content.blank?
  end

  def create_outgoing_message(message_content, agent_name: nil, preserve_waiting_since: false)
    additional_attrs = {}
    additional_attrs[:agent_name] = agent_name if agent_name.present?

    @conversation.messages.create!(
      message_type: :outgoing,
      account_id: account.id,
      inbox_id: inbox.id,
      sender: @assistant,
      content: message_content,
      additional_attributes: additional_attrs,
      preserve_waiting_since: preserve_waiting_since
    )
  end

  def handle_error(error)
    log_error(error)
    populate_error_diagnostics(error)
    Captain::CredentialCircuitBreaker.record_failure!(account) if Captain::FailurePolicy.configuration?(error)

    if error.is_a?(Captain::FailurePolicy::TransientProviderError)
      raise error
    elsif Captain::FailurePolicy.transient?(error)
      raise Captain::FailurePolicy::TransientProviderError, error.message
    end

    process_v1_handoff if conversation_pending?
    true
  end

  def populate_error_diagnostics(error)
    @response ||= {}
    @response['action_source'] ||= 'error'
    @response['action_reason'] ||= error_action_reason(error)
    @response['failure_class'] ||= Captain::FailurePolicy.classify(error).to_s
    # Matches the key V2's error responses already carry (see
    # AgentRunnerService#llm_error_response/#error_response) so
    # Captain::Conversation::FailureNotifier has one human-readable field to
    # read regardless of which runtime failed.
    @response['error'] ||= error.message
  end

  def log_error(error)
    ChatwootExceptionTracker.new(error, account: account).capture_exception
  end

  def error_action_reason(error)
    error.class.name.underscore.tr('/', '_')
  end

  def captain_v2_enabled?
    account.feature_enabled?('captain_integration_v2')
  end

  def report_v1_handoff_not_executed
    error = StandardError.new("Captain V1 handoff requested but conversation #{@conversation.display_id} is still pending")
    ChatwootExceptionTracker.new(error, account: account).capture_exception
    Rails.logger.error(
      "[CAPTAIN][ResponseBuilderJob] V1 handoff requested but not executed for account=#{account.id} " \
      "conversation=#{@conversation.display_id}"
    )
  end

  def conversation_pending?
    status = Conversation.uncached { Conversation.where(id: @conversation.id).pick(:status) }
    status == 'pending' || status == Conversation.statuses[:pending]
  end

  def conversation_captain_controllable?
    status = Conversation.uncached { Conversation.where(id: @conversation.id).pick(:status) }
    return false unless pending_status?(status) || open_status?(status)

    # The LLM may have changed status/assignment during this job (especially
    # after a V2 handoff). Evaluate against a fresh row, not the object loaded
    # before the provider call, otherwise a stale assignee or handoff marker can
    # keep the bot silent on the next customer message.
    fresh_conversation = Conversation.find(@conversation.id)
    takeover = Captain::HumanTakeoverEvaluator.new(conversation: fresh_conversation).human_takeover?
    Rails.logger.info(
      "[CAPTAIN][decision] conversation=#{fresh_conversation.display_id} status=#{status} " \
      "captain_v2=true human_takeover=#{takeover} assignee_id=#{fresh_conversation.assignee_id.inspect}"
    )
    !takeover
  end

  def pending_status?(status)
    status == 'pending' || status == Conversation.statuses[:pending]
  end

  def open_status?(status)
    status == 'open' || status == Conversation.statuses[:open]
  end
end
