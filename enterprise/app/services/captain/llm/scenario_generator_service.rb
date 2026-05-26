class Captain::Llm::ScenarioGeneratorService < Captain::BaseTaskService
  pattr_initialize [:assistant!, :focus!, { reference_scenarios: [] }]

  def perform
    response = make_api_call(model: generator_model, messages: messages)
    return response if response[:error]

    response.merge(message: extract_value(response[:message]))
  end

  def generate
    result = perform
    return '' if result[:error]

    result[:message].to_s.strip
  end

  private

  def account
    @account ||= assistant.account
  end

  def normalized_focus
    @normalized_focus ||= focus.to_s.presence_in(%w[title description instruction]) || 'instruction'
  end

  def extract_value(message)
    return '' if message.blank?

    parsed = parse_json(message)
    parsed.is_a?(Hash) ? parsed.fetch('value', '').to_s.strip : message.to_s.strip
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
    Captain::Llm::SystemPromptsService.scenario_generator(normalized_focus)
  end

  def user_prompt
    {
      focus: normalized_focus,
      assistant_context: safe_assistant_context,
      available_tools: available_tools_summary,
      reference_scenarios: normalized_reference_scenarios
    }.to_json
  end

  def safe_assistant_context
    {
      name: assistant.name,
      description: assistant.description,
      product_name: assistant.config['product_name'],
      response_guidelines: assistant.response_guidelines || [],
      guardrails: assistant.guardrails || []
    }
  end

  def available_tools_summary
    assistant.available_agent_tools.map do |tool|
      {
        id: tool[:id],
        name: tool[:title] || tool[:name],
        description: tool[:description]
      }
    end
  rescue StandardError => e
    Rails.logger.warn("[ScenarioGenerator] Failed to load tools: #{e.message}")
    []
  end

  def normalized_reference_scenarios
    Array(reference_scenarios).filter_map do |scenario|
      next unless scenario.respond_to?(:to_h)

      scenario.to_h.symbolize_keys.slice(:title, :description, :instruction, :tools)
    end
  end

  def generator_model
    InstallationConfig.find_by(name: 'CAPTAIN_OPEN_AI_MODEL')&.value.presence || GPT_MODEL
  end

  def event_name
    'scenario_generator'
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
