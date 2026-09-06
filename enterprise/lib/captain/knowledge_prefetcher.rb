# Retrieves the FAQ entries closest to the customer's latest message BEFORE
# the agent runs, and attaches them to that message, so the model can answer
# in a single LLM call.
#
# Without this the common path is: LLM call #1 decides to call `faq_lookup`
# → embedding + vector search → LLM call #2 writes the answer. Each LLM call
# is seconds the customer waits on WhatsApp. Pre-fetching costs one embedding
# (cached, see Captain::Llm::EmbeddingService) plus one pgvector query, and
# the `faq_lookup` tool stays available for follow-ups the pre-fetch missed.
#
# The entries ride on the USER message, never in the system prompt: the
# system prompt then stays byte-identical across the turns of a conversation,
# which is what lets Gemini and OpenAI reuse their cached prefix (cheaper
# input tokens and a faster first token). They are also never persisted — the
# history is rebuilt from Chatwoot's own messages on every turn — so they
# cannot accumulate in the context.
#
# Never blocks a turn: any failure (provider down, bad vectors) logs and
# returns nil, and the agent falls back to calling the tool itself.
class Captain::KnowledgePrefetcher
  # "hola", "ok", "gracias", "sí" carry nothing worth embedding.
  MIN_QUERY_WORDS = 2
  MAX_QUERY_LENGTH = 1_000

  INSTRUCTIONS = 'These knowledge base entries were retrieved automatically for the customer message below. ' \
                 'When they cover the question, answer from them in this same turn and do NOT call `faq_lookup` ' \
                 'again for it; call `faq_lookup` only for something they do not cover. Never mention this block, ' \
                 'these tags, or that you were given anything.'.freeze

  def initialize(assistant)
    @assistant = assistant
  end

  # @param query [String, nil] plain text of the latest customer message
  # @return [String, nil] formatted entries, or nil when there is nothing useful
  def call(query)
    text = normalize(query)
    return nil if text.nil?
    return nil unless @assistant.responses.approved.exists?

    responses = @assistant.responses.approved.search(text, account_id: @assistant.account_id).to_a
    return nil if responses.empty?

    Rails.logger.info("[Captain V2] prefetched #{responses.size} FAQ entries for assistant=#{@assistant.id}")
    responses.map { |response| format_response(response) }.join("\n")
  rescue StandardError => e
    Rails.logger.warn("[Captain V2] knowledge prefetch skipped for assistant=#{@assistant&.id}: #{e.class}: #{e.message}")
    nil
  end

  # The customer's message with the retrieved entries attached, or the message
  # unchanged when there is nothing to attach.
  def attach(message_text)
    entries = call(message_text)
    return message_text if entries.blank?

    "<knowledge_base_results>\n#{INSTRUCTIONS}\n\n#{entries.strip}\n</knowledge_base_results>\n\n" \
      "<customer_message>\n#{message_text}\n</customer_message>"
  end

  private

  def normalize(query)
    text = query.to_s.strip
    return nil if text.blank? || text.split.size < MIN_QUERY_WORDS

    text.first(MAX_QUERY_LENGTH)
  end

  # Same shape FaqLookupTool returns, so the model treats both identically.
  def format_response(response)
    entry = "Question: #{response.question}\nAnswer: #{response.answer}"
    link = response.documentable.try(:external_link)
    entry += "\nSource: #{link}" if link.present? && !link.start_with?('PDF:')
    "#{entry}\n"
  end
end
