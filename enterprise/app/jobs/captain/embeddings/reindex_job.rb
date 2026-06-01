# Regenerates all of an account's embeddings (FAQ responses + article terms)
# with the account's currently selected embedding model, then flips the ACTIVE
# pointer so search starts using the new model. Until this completes, search
# keeps filtering by the old active model (graceful, possibly partial, results).
#
# Idempotent: converges to the account's current selection and no-ops once the
# active pointer already matches, so duplicate enqueues are safe.
class Captain::Embeddings::ReindexJob < ApplicationJob
  queue_as :low

  def perform(account_id, _target_model = nil)
    account = Account.find_by(id: account_id)
    return if account.nil?

    service = Captain::Llm::EmbeddingService.new(account: account)
    target = service.model_name
    # Another reconcile may have already converged the account.
    return if Captain::Embeddings::Manager.active_model(account) == target

    reindex_responses(account, service, target)
    reindex_article_embeddings(account, service, target)

    Captain::Embeddings::Manager.set_active!(account, target)
  end

  private

  def reindex_responses(account, service, target)
    Captain::AssistantResponse.where(account_id: account.id).find_each do |response|
      vector = service.get_embedding("#{response.question}: #{response.answer}")
      next if vector.blank?

      # update_columns skips callbacks so we don't re-enqueue UpdateEmbeddingJob.
      response.update_columns(embedding: vector, embedding_model: target)
    end
  end

  def reindex_article_embeddings(account, service, target)
    ArticleEmbedding.joins(:article)
                    .where(articles: { account_id: account.id })
                    .find_each do |article_embedding|
      vector = service.get_embedding(article_embedding.term)
      next if vector.blank?

      article_embedding.update_columns(embedding: vector, embedding_model: target)
    end
  end
end
