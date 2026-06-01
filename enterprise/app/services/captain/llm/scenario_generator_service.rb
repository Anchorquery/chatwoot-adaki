class Captain::Llm::ScenarioGeneratorService < Captain::BaseTaskService
  RESPONSE_SCHEMA = Captain::Llm::ScenarioGeneratorSchema

  pattr_initialize [:account!, :assistant!, :prompt!]

  def perform
    response = make_api_call(model: generator_model, messages: messages, schema: RESPONSE_SCHEMA)
    return response if response[:error]

    response.merge(message: extract_payload(response[:message]))
  end

  private

  def extract_payload(message)
    return {} if message.blank?

    data = message.is_a?(Hash) ? message.deep_symbolize_keys : {}
    {
      title: data[:title].to_s.strip,
      description: data[:description].to_s.strip,
      instruction: data[:instruction].to_s.strip
    }
  end

  def messages
    [
      { role: 'system', content: system_prompt },
      { role: 'user', content: user_prompt }
    ]
  end

  def system_prompt
    tools_list = available_tools_text

    <<~PROMPT
      You are an expert assistant configuration writer for a customer-support AI platform.
      Your task is to generate a complete scenario definition for an AI assistant.

      A scenario defines how the assistant should behave in a specific situation.
      It has three parts:
      - title: A short label for the scenario (e.g. "Angry customer", "Refund request")
      - description: One sentence explaining when this scenario applies
      - instruction: Step-by-step Markdown instructions the assistant will follow

      #{tools_list.present? ? "Available tools the assistant can use:\n#{tools_list}\n\nTo reference a tool in the instruction, use exactly this format: [@Tool Name](tool://tool_id)" : 'No tools are configured for this assistant.'}

      Write the title, description, and instruction in #{locale_name}.
      Be concrete, actionable, and professional. Do not invent tool IDs that are not listed above.
    PROMPT
  end

  def user_prompt
    parts = [
      "Assistant name: #{assistant.name}",
      ("Assistant description: #{assistant.description}" if assistant.description.present?),
      '',
      "Generate a scenario for the following situation:",
      prompt
    ].compact
    parts.join("\n")
  end

  def available_tools_text
    tools = assistant.available_agent_tools
    return '' if tools.blank?

    tools.map { |t| "- #{t[:name]} (tool://#{t[:id]}): #{t[:description]}" }.join("\n")
  end

  def locale_name
    code = account.locale.to_s
    LANGUAGES_CONFIG.values.find { |v| v[:iso_639_1_code] == code }&.dig(:name) || code.presence || 'English (en)'
  end

  def event_name
    'scenario_generator'
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

  def generator_model
    resolved_generator_model
  end

  def build_follow_up_context?
    false
  end
end
