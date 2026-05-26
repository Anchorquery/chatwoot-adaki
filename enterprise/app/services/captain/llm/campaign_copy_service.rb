class Captain::Llm::CampaignCopyService < Captain::BaseTaskService
  pattr_initialize [:account!, :prompt!, { tone: 'friendly', goal: 'informative' }]

  def perform
    response = make_api_call(model: copy_model, messages: messages)
    return response if response[:error]

    response.merge(message: extract_payload(response[:message]))
  end

  private

  def extract_payload(content)
    parsed = parse_json(content)
    return blank_payload unless parsed.is_a?(Hash)

    {
      message: parsed['message'].to_s.strip,
      variants: extract_variants(parsed['variants'])
    }
  end

  def extract_variants(raw)
    Array(raw).filter_map do |variant|
      text = variant.is_a?(Hash) ? (variant['text'] || variant[:text]) : variant
      text = text.to_s.strip
      next if text.blank?

      { text: text }
    end
  end

  def blank_payload
    { message: '', variants: [] }
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
      You are a senior campaign copywriter.
      Return strict JSON only with this schema:
      {
        "message": "Main message",
        "variants": [
          { "text": "Variant 1" },
          { "text": "Variant 2" },
          { "text": "Variant 3" }
        ]
      }
      Write for human review, keep the tone consistent, and keep the text concise.
      Use Liquid variables only when relevant, such as {{contact.name}}.
      Reply in the same language as the brief.
    PROMPT
  end

  def user_prompt
    "Goal: #{goal}\nTone: #{tone}\nBrief: #{prompt}"
  end

  def copy_model
    InstallationConfig.find_by(name: 'CAPTAIN_OPEN_AI_MODEL')&.value.presence || GPT_MODEL
  end

  def event_name
    'campaign_copy'
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
