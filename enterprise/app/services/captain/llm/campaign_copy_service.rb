class Captain::Llm::CampaignCopyService < Captain::BaseTaskService
  pattr_initialize [:account!, :prompt!, {
    tone: 'friendly',
    goal: 'informative',
    assistant: nil,
    use_emojis: false,
    style: 'standard',
    context_source: 'none'
  }]

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
      title: parsed['title'].to_s.strip,
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
    { title: '', message: '', variants: [] }
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
      You are a senior campaign copywriter specializing in WhatsApp messaging.
      Return strict JSON only with this schema:
      {
        "title": "Short campaign label (5-8 words)",
        "message": "Main message",
        "variants": [
          { "text": "Variant 1" },
          { "text": "Variant 2" },
          { "text": "Variant 3" }
        ]
      }
      #{assistant_context}
      #{emoji_instruction}
      #{style_instruction}
      FORMATTING — WhatsApp markdown only (no HTML, no Markdown headings):
      - *bold* for key product names, prices, or CTAs
      - _italic_ for tone/emphasis
      - To separate paragraphs, use the literal \n escape inside the JSON string. Example: "First paragraph.\n\nSecond paragraph."
      - Bullet lists: put each bullet on its own line using \n before each bullet. Example: "Intro:\n• Feature 1\n• Feature 2"
      - Never use #, ##, **, or any HTML tags
      - The JSON "message" and "variants[].text" values MUST contain \n characters for line breaks — never output a single flat paragraph when the content has multiple ideas.
      The message AND every variant must all reflect the same context and knowledge above.
      Each variant should be a distinct rephrasing — different angle or emphasis, not just synonyms.
      IMPORTANT: If the knowledge contains specific product names, prices, or lists — include them explicitly. Do NOT summarize or generalize; name the products and prices directly.
      If source URLs appear in the knowledge, include the most relevant one as a plain URL where it adds value.
      Write for human review, keep the tone consistent across all texts.
      Use Liquid variables only when relevant, such as {{contact.name}}.
      Reply in the same language as the brief.
    PROMPT
  end

  def assistant_context
    return '' unless assistant.present?

    parts = [
      'Assistant context:',
      "- Name: #{assistant.name}",
      "- Description: #{assistant.description}",
      "- Product: #{assistant.config['product_name'].presence || 'this product'}"
    ]

    scenario_titles = assistant.scenarios.enabled.map(&:title).join(', ')
    parts << "- Scenarios: #{scenario_titles}" if scenario_titles.present?

    case context_source.to_s
    when 'guidelines'
      guidelines = Array(assistant.response_guidelines)
      guardrails = Array(assistant.guardrails)
      parts << "- Behavioral guidelines: #{guidelines.join('; ')}" if guidelines.any?
      parts << "- Guardrails (must never violate): #{guardrails.join('; ')}" if guardrails.any?
    when 'documents'
      knowledge = search_assistant_documents
      parts << "- Relevant product knowledge:\n#{knowledge}" if knowledge.present?
    end

    parts << "Write consistent with this assistant's style and brand voice."
    parts.join("\n")
  end

  def document_responses_scope
    assistant.responses.approved
             .where(documentable_type: ['Captain::Document', nil])
  end

  def search_assistant_documents
    embedding = Captain::Llm::EmbeddingService.new(account: account, purpose: :search).get_embedding(prompt)
    results = if embedding.present?
                scope = Captain::Embeddings::Manager.scope_to_active(document_responses_scope, account)
                scope.nearest_neighbors(:embedding, embedding, distance: 'cosine').limit(5)
              else
                fallback_responses
              end
    format_document_results(results)
  rescue StandardError => e
    Rails.logger.warn("[CampaignCopy] Embedding search failed (#{e.class}): #{e.message}. Using recent responses.")
    format_document_results(fallback_responses)
  end

  def fallback_responses
    document_responses_scope.order(created_at: :desc).limit(5)
  end

  def format_document_results(results)
    return '' if results.blank?

    results.map do |r|
      entry = "  Q: #{r.question}\n  A: #{r.answer}"
      doc = r.documentable
      link = doc.is_a?(Captain::Document) ? doc.external_link.to_s.presence : nil
      entry += "\n  Source: #{link}" if link && !link.start_with?('PDF:') && !link.end_with?('.pdf')
      entry
    end.join("\n")
  end

  def emoji_instruction
    use_emojis ? 'Use emojis naturally throughout the text.' : 'Do NOT use emojis.'
  end

  def style_instruction
    case style.to_s
    when 'concise'
      'Keep the message and every variant under 80 characters each. Be punchy and direct.'
    when 'detailed'
      'Write longer texts for message and variants. Include relevant context, supporting detail, and a clear call to action. Aim for 2-4 sentences each.'
    else
      'Use normal message length (1-2 sentences) for message and variants.'
    end
  end

  def user_prompt
    "Goal: #{goal}\nTone: #{tone}\nBrief: #{prompt}"
  end

  def copy_model
    resolved_generator_model
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
