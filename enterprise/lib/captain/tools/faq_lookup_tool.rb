class Captain::Tools::FaqLookupTool < Captain::Tools::BasePublicTool
  description 'Search FAQ responses using semantic similarity to find relevant answers'
  param :query, type: 'string', desc: 'The question or topic to search for in the FAQ database'

  def perform(_tool_context, query:)
    log_tool_usage('searching', { query: query })

    # Use existing vector search on approved responses. Pass account_id so the
    # query is embedded with — and filtered to — the account's active embedding model.
    #
    # `search` is a plain nearest-neighbours query: it always returns the five
    # closest rows, however far away they are, so "No relevant FAQs found"
    # could never happen and a generic "I want more information" came back
    # with five products the model then pasted as links. Judge relevance with
    # the same distance bar the prefetch already uses (see
    # Captain::KnowledgePrefetcher) so an off-topic query really is empty and
    # the prompt's "ask which product" path can run.
    responses = @assistant.responses.approved.search(query, account_id: @assistant.account_id)
                          .select { |response| Captain::KnowledgePrefetcher.within_distance_threshold?(response) }

    if responses.empty?
      log_tool_usage('no_results', { query: query })
      "No relevant FAQs found for: #{query}"
    else
      log_tool_usage('found_results', { query: query, count: responses.size })
      format_responses(responses)
    end
  rescue Captain::Llm::EmbeddingService::EmbeddingsError => e
    # Degrade gracefully: an embedding/provider failure should not kill the
    # whole agent turn — let the model answer without FAQ context or hand off.
    log_tool_usage('embedding_error', { query: query, error: e.message })
    'FAQ search is temporarily unavailable. Answer from the conversation context or hand off to a human agent if needed.'
  end

  private

  def format_responses(responses)
    responses.map { |response| format_response(response) }.join
  end

  def format_response(response)
    formatted_response = "
        Question: #{response.question}
        Answer: #{response.answer}
        "
    if should_show_source?(response)
      formatted_response += "
          Source: #{response.documentable.external_link}
          "
    end

    formatted_response
  end

  def should_show_source?(response)
    return false if response.documentable.blank?
    return false unless response.documentable.try(:external_link)

    # Don't show source if it's a PDF placeholder
    external_link = response.documentable.external_link
    !external_link.start_with?('PDF:')
  end
end
