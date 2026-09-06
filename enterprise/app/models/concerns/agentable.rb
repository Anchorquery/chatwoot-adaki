module Concerns::Agentable
  extend ActiveSupport::Concern

  def agent
    Agents::Agent.new(
      name: agent_name,
      instructions: ->(context) { agent_instructions(context) },
      tools: agent_tools,
      model: agent_model,
      temperature: agent_temperature,
      response_schema: agent_response_schema,
      params: agent_params
    )
  end

  def agent_instructions(context = nil)
    enhanced_context = prompt_context

    if context
      state = context.context[:state] || {}
      config = state[:assistant_config] || {}
      enhanced_context = enhanced_context.merge(
        conversation: state[:conversation] || {},
        contact: config['feature_contact_attributes'].present? ? state[:contact] : nil,
        campaign: state[:campaign] || {},
        channel_type: state[:channel_type],
        # Lets the prompt switch to plain-text formatting rules on WhatsApp/SMS
        # (see prompts/snippets/formatting.liquid). Captain::ChatTextFormatter
        # still flattens whatever Markdown slips through on the way out.
        plain_text_channel: Captain::ChatTextFormatter.chat_channel?(state[:channel_type])
      )
    end

    Captain::PromptRenderer.render(template_name, enhanced_context.with_indifferent_access)
  end

  private

  def agent_name
    raise NotImplementedError, "#{self.class} must implement agent_name"
  end

  def template_name
    self.class.name.demodulize.underscore
  end

  def agent_tools
    []  # Default implementation, override if needed
  end

  # Model slug handed to the ai-agents gem (and ultimately RubyLLM). RubyLLM
  # routes by slug, so this must reflect the account's configured provider/model
  # (e.g. a Gemini slug) — otherwise the playground / Captain V2 runner always
  # talks to OpenAI regardless of the account's credentials. The per-credential
  # API key is injected separately by AgentRunnerService (per-thread context).
  # Falls back to the legacy InstallationConfig model for installs that have not
  # enabled any model in the platform UI yet.
  # A slug the resolver returned already came from the provider's own model
  # list, so it is used verbatim — running it through the catalog aliases here
  # would undo exactly what Platform::Models::Resolver guarantees. Only the
  # legacy InstallationConfig/default values, which are ours, are canonicalised.
  def agent_model
    resolved_slug = agent_resolution&.dig(:model_slug).presence
    return resolved_slug if resolved_slug

    Llm::Models.canonical_model_slug(
      InstallationConfig.find_by(name: 'CAPTAIN_OPEN_AI_MODEL')&.value.presence || LlmConstants::DEFAULT_MODEL
    )
  end

  # Feature key used to resolve the account's model. Override in including
  # models if a more specific feature applies.
  def agent_feature_key
    'assistant'
  end

  # Provider of the resolved credential/model. Prefers the resolved credential,
  # then the model registry, defaulting to openai.
  def agent_provider
    credential = agent_resolution&.dig(:credential)
    provider = credential.provider.to_s if credential.respond_to?(:provider)
    provider = provider.presence || Llm::Models.models.dig(agent_model, 'provider').presence || 'openai'
    provider == 'google' ? 'gemini' : provider
  end

  def agent_resolution
    return @agent_resolution if defined?(@agent_resolution)

    account = try(:account)
    preferred_slug = account&.try(:captain_models)&.[]('assistant')
    @agent_resolution = account && Platform::Models::Resolver.resolve(
      account: account,
      feature: agent_feature_key,
      preferred_slug: preferred_slug
    )
  end

  def agent_temperature
    return nil if %w[gpt-5 gemini-3].any? { |prefix| agent_model.start_with?(prefix) }

    temperature.present? ? temperature.to_f : 0.7
  end

  # Gemini rejects function calling combined with a JSON response mime type, and
  # DeepSeek's Captain models do not advertise structured-output support.
  # Captain agents rely on tools (handoff/search), so Gemini and DeepSeek reply
  # in plain text — AgentRunnerService#process_agent_result already wraps a
  # plain string output into { response:, reasoning: }, and handoffs are
  # signalled via the HandoffTool, not the schema.
  def agent_response_schema
    return nil if %w[gemini deepseek].include?(agent_provider)

    Captain::ResponseSchema
  end

  # Provider-specific request params for this agent. Agents::Agent forwards
  # them to the chat and RubyLLM deep-merges them into the payload, so the
  # nested Gemini `generationConfig` from both halves below combines instead
  # of one replacing the other.
  def agent_params
    thinking = agent_thinking_params
    thinking.deep_merge(
      Llm::OutputLimit.params_for(
        provider: agent_provider,
        model: agent_model,
        max_tokens: max_response_tokens_value,
        thinking_params: thinking
      )
    )
  end

  # Per-assistant override for the reply length cap. Scenarios inherit it.
  def max_response_tokens_value
    Llm::OutputLimit::DEFAULT_MAX_TOKENS
  end

  # Caps (or disables) the model's internal reasoning — see Llm::Thinking for
  # why the default is 'off'. Reaches the request because Agents::Agent
  # forwards `params` to the chat and RubyLLM deep-merges them into the
  # payload. A scenario inherits the level from its assistant.
  def agent_thinking_params
    Llm::Thinking.params_for(
      provider: agent_provider,
      model: agent_model,
      level: reasoning_level_value,
      supported_efforts: agent_reasoning_efforts
    )
  end

  # Efforts the model's own row says it accepts (seeded on import, corrected
  # from provider rejections, editable in the providers view). Nil when there
  # is no row or it says nothing yet, in which case Llm::Thinking falls back
  # to the family seed. Deliberately not memoized: AgentRunnerService may
  # learn from a rejection and rebuild the agents within the same request.
  def agent_reasoning_efforts
    Llm::ReasoningCapabilities.stored_efforts(agent_model_row&.reasoning_config)
  end

  def agent_model_row
    credential = agent_resolution&.dig(:credential)
    return nil unless credential.respond_to?(:models)

    slugs = [agent_resolution[:model_slug], agent_model].compact.uniq
    credential.models.find_by(slug: slugs)
  end

  def prompt_context
    raise NotImplementedError, "#{self.class} must implement prompt_context"
  end
end
