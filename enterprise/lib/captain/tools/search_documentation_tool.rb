require 'agents'

class Captain::Tools::SearchDocumentationTool < Captain::Tools::BasePublicTool
  # Same vector index and query as FaqLookupTool — kept for backwards
  # compatibility with prompts/scenarios that name it. The description tells
  # the model so it does not "verify" one tool with the other: each extra call
  # costs an embedding request plus a full LLM round-trip while the customer
  # waits.
  description 'Search the account knowledge base for documentation and product answers. ' \
              'Same index as faq_lookup: call only one of them per question, never both.'
  param :query, type: 'string', desc: 'The question or topic to search for in the documentation'

  def perform(_tool_context, query:)
    log_tool_usage('searching_documentation', { query: query })

    responses = @assistant.responses.approved.search(query, account_id: @assistant.account_id).to_a
    return 'No relevant documentation found for this query.' if responses.empty?

    responses.map { |response| format_response(response) }.join
  rescue Captain::Llm::EmbeddingService::EmbeddingsError => e
    log_tool_usage('embedding_error', { query: query, error: e.message })
    'Documentation search is temporarily unavailable. Answer from the conversation context or ask one clarifying question.'
  end

  private

  def format_response(response)
    formatted = "\nQuestion: #{response.question}\nAnswer: #{response.answer}\n"
    return formatted unless response.documentable.present? && response.documentable.try(:external_link)

    "#{formatted}Source: #{response.documentable.external_link}\n"
  end
end
