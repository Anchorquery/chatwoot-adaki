require 'benchmark'

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

  # Held for the whole LLM run. Longer than the worst realistic turn
  # (RubyLLM request_timeout 30s x a couple of tool round-trips) so it is a
  # deadlock guard, not a timeout: if a worker dies mid-run the lock frees
  # itself instead of silencing the conversation forever.
  LOCK_TTL = 3.minutes
  # Polled in-process instead of re-enqueued: upstream Chatwoot's
  # ResponseSchedulerService enqueues instantly and only ever discards by
  # newer message, never by a Sidekiq scheduled-set wait (see docs/adaki/
  # captain-plan-latencia-2026-09.md fase 1). LOCK_POLL_INTERVAL x
  # MAX_LOCK_ATTEMPTS is comfortably past LOCK_TTL, so this only gives up if
  # something is genuinely wrong rather than merely slow.
  LOCK_POLL_INTERVAL = 1.second
  MAX_LOCK_ATTEMPTS = 60

  def perform(conversation, assistant, debounce_wait: 0)
    @conversation = conversation
    @inbox = conversation.inbox
    @assistant = assistant
    @perform_started_at = Time.current
    @queue_wait_ms = enqueued_at.present? ? ((@perform_started_at - enqueued_at) * 1000).round : nil
    @lock_wait_ms = 0

    # See Enterprise::MessageTemplates::HookExecutionService#schedule_captain_response:
    # the job is enqueued immediately now, so the debounce (coalescing a
    # customer's message burst into one run) happens here instead of on
    # Sidekiq's scheduled set, which used to add 2.5-7.5s of poller latency
    # on top of every wait.
    sleep(debounce_wait) if debounce_wait.to_f.positive?

    return if superseded_by_newer_message?
    return unless conversation_captain_controllable?

    with_conversation_lock { perform_locked }
  end

  private

  delegate :account, :inbox, to: :@conversation

  # The original body. Errors are handled inside the lock so a handoff
  # message written by handle_error cannot interleave with another run's
  # reply; a re-raised (retryable) error still releases the lock on its way
  # out through #with_conversation_lock.
  def perform_locked
    Current.executed_by = @assistant

    dispatch_response
    record_captain_v2_usage!
  rescue ActiveStorage::FileNotFoundError, Faraday::BadRequestError => e
    handle_error(e)
    raise e
  rescue StandardError => e
    handle_error(e)
  ensure
    log_timing
    Current.executed_by = nil
  end

  # See Captain::Assistant::AgentRunnerService: this used to run inside
  # #generate_response, before dispatch_response had created the outgoing
  # message — 2 transactions plus a retrying advisory lock
  # (Adaki::AuditLogger#acquire_advisory_lock!) on the customer's critical
  # path for no reason, since neither write affects what gets replied. Moved
  # here, after the message already exists, reading the tokens off the same
  # timing hash log_timing uses. A no-op outside V2 (V1 usage goes through
  # Captain::ChatHelperAdaki instead) or when dispatch_response raised before
  # ever reaching AgentRunnerService#attach_timing!. See docs/adaki/
  # captain-plan-latencia-2026-09.md fase 3.5.
  def record_captain_v2_usage!
    timing = @response.is_a?(Hash) ? @response['timing'] : nil
    return if timing.blank?

    Adaki::CaptainUsageTracker.record!(
      account: account,
      feature: 'assistant',
      input_tokens: timing[:input_tokens].to_i,
      output_tokens: timing[:output_tokens].to_i,
      assistant_id: @assistant&.id
    )
  end

  # See docs/adaki/captain-plan-latencia-2026-09.md fase 0: one line per
  # response to see where a turn's time actually goes without guessing.
  def log_timing
    timing = @response.is_a?(Hash) ? (@response['timing'] || {}) : {}
    total_ms = ((Time.current - @perform_started_at) * 1000).round

    Rails.logger.info(
      "[CAPTAIN][timing] conversation=#{@conversation.display_id} queue_wait_ms=#{@queue_wait_ms.inspect} " \
      "lock_ms=#{lock_wait_ms} history_ms=#{@history_ms.inspect} prefetch_ms=#{timing[:prefetch_ms].inspect} " \
      "llm_ms=#{timing[:llm_ms].inspect} tools_calls=#{timing[:tools_calls].inspect} " \
      "agent=#{@response['agent_name'].inspect} input_tokens=#{timing[:input_tokens].inspect} " \
      "output_tokens=#{timing[:output_tokens].inspect} total_ms=#{total_ms}"
    )
  end

  def lock_wait_ms
    @lock_wait_ms.round
  end

  # One Captain run at a time per conversation. Two runs could otherwise
  # overlap — a retry alongside a fresh message, or an attachment job whose
  # extra wait let the next message's job start first — and produce two
  # replies to the same question, out of order, each having read a history
  # the other was about to change.
  #
  # A job that cannot take the lock polls for it in-process instead of
  # re-enqueuing itself: re-enqueuing paid the same Sidekiq scheduled-set
  # poller latency the fase-1 debounce fix removed (see perform above), for
  # the same conversation-lock case. Whatever arrived while the LLM was busy
  # still gets answered, right after the reply it was waiting on.
  def with_conversation_lock(&)
    lock_key = "captain:conversation:#{@conversation.id}"
    manager = Redis::LockManager.new
    attempt = 0

    loop do
      return if manager.with_lock(lock_key, LOCK_TTL, &)

      attempt += 1
      return report_lock_timeout(lock_key) if attempt >= MAX_LOCK_ATTEMPTS

      wait_start = Time.current
      sleep(LOCK_POLL_INTERVAL)
      @lock_wait_ms += (Time.current - wait_start) * 1000
    end
  end

  def report_lock_timeout(lock_key)
    error = StandardError.new("Captain could not acquire #{lock_key} after #{MAX_LOCK_ATTEMPTS} attempts")
    ChatwootExceptionTracker.new(error, account: account).capture_exception
  end

  # WhatsApp users send thoughts as several short messages in a row ("hola",
  # "una pregunta", "cuánto vale el pack de 3"). Each one enqueues this job;
  # without this guard three LLM runs would start almost at once (occupying
  # the whole 3-thread captain capsule), reply three times, and the first
  # replies would answer an incomplete question. The hook delays the enqueue
  # a little (see HookExecutionService#captain_debounce_wait) so the LAST
  # message's job sees the whole burst in the history; every earlier job
  # finds a newer incoming message than the one that enqueued it and stands
  # down. `enqueued_at` is nil under perform_now (specs, console): never skip.
  def superseded_by_newer_message?
    return false if enqueued_at.blank?

    newer = @conversation.messages.incoming.where(private: false).exists?(['created_at > ?', enqueued_at])
    return false unless newer

    Rails.logger.info(
      "[CAPTAIN][skip] account=#{account.id} conversation=#{@conversation.display_id} reason=superseded_by_newer_message"
    )
    true
  end

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
  # time. The customer still receives the standard handoff, while
  # FailureNotifier records the circuit cause as a private note for the team.
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
  # handoff with a private diagnostic note instead of an invisible dependency on shared usage/limits. See
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
    history = nil
    elapsed = Benchmark.realtime do
      history = Captain::Conversation::HistoryBuilder.new(conversation: @conversation, assistant: @assistant).call
    end
    @history_ms = (elapsed * 1000).round
    history
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
      # handoff was actually caused by an infrastructure failure, not a
      # legitimate escalation. After
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
      # The LLM writes Markdown; on WhatsApp/SMS headings and [text](url)
      # links arrive as literal symbols. See Captain::ChatTextFormatter —
      # a no-op for channels that render Markdown themselves.
      content: Captain::ChatTextFormatter.format(message_content, channel_type: inbox.channel_type),
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
