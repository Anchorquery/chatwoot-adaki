class Captain::Llm::AssistantConfigGeneratorService < Captain::BaseTaskService
  ALLOWED_FIELDS = %w[description response_guidelines guardrails handoff_message resolution_message].freeze

  pattr_initialize [:account!, :assistant!, { fields: ALLOWED_FIELDS }]

  def perform
    response = make_api_call(model: generator_model, messages: messages)
    return response if response[:error]

    response.merge(message: extract_payload(response[:message]))
  end

  private

  def extract_payload(content)
    parsed = parse_json(content)
    return {} unless parsed.is_a?(Hash)

    result = {}
    if requested?('description') && parsed['description'].present?
      result[:description] = parsed['description'].to_s.strip
    end
    if requested?('response_guidelines')
      result[:response_guidelines] = clean_array(parsed['response_guidelines'])
    end
    if requested?('guardrails')
      result[:guardrails] = clean_array(parsed['guardrails'])
    end
    if requested?('handoff_message') && parsed['handoff_message'].present?
      result[:handoff_message] = parsed['handoff_message'].to_s.strip
    end
    if requested?('resolution_message') && parsed['resolution_message'].present?
      result[:resolution_message] = parsed['resolution_message'].to_s.strip
    end
    result
  end

  def clean_array(raw)
    Array(raw).map(&:to_s).map(&:strip).reject(&:blank?)
  end

  def requested?(field)
    fields.include?(field)
  end

  def parse_json(content)
    cleaned = content.to_s.strip.sub(/\A```(?:json)?\s*/i, '').sub(/\s*```\z/, '')
    JSON.parse(cleaned)
  rescue JSON::ParserError
    nil
  end

  def messages
    [
      { role: 'system', content: system_prompt },
      { role: 'user', content: user_prompt }
    ]
  end

  def system_prompt
    <<~PROMPT
      You are an expert AI assistant configurator for a customer support platform.
      Based on the assistant identity and knowledge base content, generate configuration fields.
      Return strict JSON only with this schema (include all requested fields):
      {
        "description": "2-4 sentence description of what this assistant does and who it helps",
        "response_guidelines": ["Concrete guideline 1", "Concrete guideline 2", "Concrete guideline 3", "Concrete guideline 4"],
        "guardrails": ["Never do X", "Never share Y", "Always escalate when Z"],
        "handoff_message": "Friendly message shown when transferring to a human agent",
        "resolution_message": "Friendly closing message shown when the conversation is resolved"
      }
      Be specific to the product and knowledge base — no generic placeholder text.
      For response_guidelines: 4-6 actionable rules specific to this product and content.
      For guardrails: 3-5 safety and scope rules relevant to this assistant's domain.
      Use the same language as the knowledge base content.
    PROMPT
  end

  def user_prompt
    parts = [
      "Assistant name: #{assistant.name}",
      "Product: #{assistant.config['product_name'].presence || 'not specified'}",
      ("Current description: #{assistant.description}" if assistant.description.present?),
      '',
      "Generate these fields: #{fields.join(', ')}",
      '',
      knowledge_context
    ].compact
    parts.join("\n")
  end

  def knowledge_context
    docs = fetch_knowledge
    return 'No knowledge base available yet.' if docs.blank?

    "Knowledge base sample:\n#{docs}"
  end

  def fetch_knowledge
    assistant.responses.approved.order(created_at: :desc).limit(10)
             .map { |r| "  Q: #{r.question}\n  A: #{r.answer}" }.join("\n")
  rescue StandardError
    ''
  end

  def generator_model
    InstallationConfig.find_by(name: 'CAPTAIN_OPEN_AI_MODEL')&.value.presence || GPT_MODEL
  end

  def event_name
    'assistant_config_generator'
  end

  def llm_credential
    @llm_credential ||= system_llm_credential
  end

  def captain_tasks_enabled?
    true
  end

  def counts_toward_usage?
    false
  end

  def build_follow_up_context?
    false
  end
end
