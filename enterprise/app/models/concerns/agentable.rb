module Concerns::Agentable
  extend ActiveSupport::Concern

  def agent
    Agents::Agent.new(
      name: agent_name,
      instructions: ->(context) { agent_instructions(context) },
      tools: agent_tools,
      model: agent_model,
      temperature: temperature.to_f || 0.7,
      response_schema: agent_response_schema
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
  # API key is injected separately by AgentRunnerService via on_chat_created.
  # Falls back to the legacy InstallationConfig model for installs that have not
  # enabled any model in the platform UI yet.
  def agent_model
    resolved_agent_model.presence ||
      InstallationConfig.find_by(name: 'CAPTAIN_OPEN_AI_MODEL')&.value.presence ||
      LlmConstants::DEFAULT_MODEL
  end

  # Feature key used to resolve the account's model. Override in including
  # models if a more specific feature applies.
  def agent_feature_key
    'assistant'
  end

  def resolved_agent_model
    account = try(:account)
    return nil if account.blank?

    Platform::Models::Resolver.resolve(account: account, feature: agent_feature_key)&.dig(:model_slug)
  end

  def agent_response_schema
    Captain::ResponseSchema
  end

  def prompt_context
    raise NotImplementedError, "#{self.class} must implement prompt_context"
  end
end
