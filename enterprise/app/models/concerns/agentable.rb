module Concerns::Agentable
  extend ActiveSupport::Concern

  def agent
    Agents::Agent.new(
      name: agent_name,
      instructions: ->(context) { agent_instructions(context) },
      tools: agent_tools,
      model: agent_model,
      temperature: temperature.to_f || 0.7,
      response_schema: agent_response_schema,
      params: agent_thinking_params
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
        campaign: state[:campaign] || {}
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
  def agent_model
    agent_resolution&.dig(:model_slug).presence ||
      InstallationConfig.find_by(name: 'CAPTAIN_OPEN_AI_MODEL')&.value.presence ||
      LlmConstants::DEFAULT_MODEL
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
    provider.presence || Llm::Models.models.dig(agent_model, 'provider').presence || 'openai'
  end

  def agent_resolution
    return @agent_resolution if defined?(@agent_resolution)

    account = try(:account)
    @agent_resolution = account && Platform::Models::Resolver.resolve(account: account, feature: agent_feature_key)
  end

  # Gemini rejects function calling combined with a JSON response mime type, and
  # a response_schema forces `responseMimeType: application/json`. Captain agents
  # rely on tools (handoff/search), so for Gemini we skip the structured schema
  # and let the agent reply in plain text — AgentRunnerService#process_agent_result
  # already wraps a plain string output into { response:, reasoning: }, and
  # handoffs are signalled via the HandoffTool, not the schema.
  def agent_response_schema
    return nil if agent_provider == 'gemini'

    Captain::ResponseSchema
  end

  # Caps (or disables) the model's internal reasoning — see Llm::Thinking for
  # why the default is 'off'. Reaches the request because Agents::Agent
  # forwards `params` to the chat and RubyLLM deep-merges them into the
  # payload. A scenario inherits the level from its assistant.
  def agent_thinking_params
    Llm::Thinking.params_for(
      provider: agent_provider,
      model: agent_model,
      level: reasoning_level_value
    )
  end

  def prompt_context
    raise NotImplementedError, "#{self.class} must implement prompt_context"
  end
end
