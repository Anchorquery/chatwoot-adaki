class Captain::Llm::UpdateEmbeddingJob < ApplicationJob
  queue_as :low

  def perform(record, content)
    account = record.account if record.respond_to?(:account)
    service = Captain::Llm::EmbeddingService.new(account: account, account_id: record.account_id)
    embedding = service.get_embedding(content)
    return if embedding.blank?

    # Tag the vector with the model that produced it so search never compares
    # across providers (OpenAI vs Gemini).
    record.update!(embedding: embedding, embedding_model: service.model_name)
  end
end
