module Enterprise::Concerns::Article
  extend ActiveSupport::Concern

  included do
    after_save :add_article_embedding, if: -> { saved_change_to_title? || saved_change_to_description? || saved_change_to_content? }

    def self.add_article_embedding_association
      has_many :article_embeddings, dependent: :destroy_async
    end

    add_article_embedding_association

    def self.vector_search(params)
      account = params[:account_id].present? ? Account.find_by(id: params[:account_id]) : nil
      service = Captain::Llm::EmbeddingService.new(account: account, account_id: params[:account_id], purpose: :search)
      embedding = service.get_embedding(params['query'])
      records = joins(
        :category
      ).search_by_category_slug(
        params[:category_slug]
      ).search_by_category_locale(params[:locale]).search_by_author(params[:author_id]).search_by_status(params[:status])
      filtered_article_ids = records.pluck(:id)

      # Only compare against vectors of the account's active embedding model so
      # OpenAI and Gemini vectors (same column) are never mixed.
      embeddings = ArticleEmbedding.where(article_id: filtered_article_ids)
      embeddings = Captain::Embeddings::Manager.scope_to_active(embeddings, account)

      article_ids = embeddings.nearest_neighbors(:embedding, embedding, distance: 'cosine')
                              .limit(5)
                              .pluck(:article_id)

      # Fetch the articles by the IDs obtained from the nearest neighbors search
      where(id: article_ids)
    end
  end

  def add_article_embedding
    return unless account.feature_enabled?('help_center_embedding_search')

    Portal::ArticleIndexingJob.perform_later(self)
  end

  def generate_and_save_article_seach_terms
    terms = generate_article_search_terms
    article_embeddings.destroy_all
    terms.each { |term| article_embeddings.create!(term: term) }
  end

  # Provider-aware (OpenAI/Gemini) via Captain::Llm::ArticleSearchTermsService.
  # Replaces the previous raw OpenAI HTTP call hardcoded to gpt-4o +
  # ENV['OPENAI_API_KEY'], which ignored the account's configured provider.
  def generate_article_search_terms
    Captain::Llm::ArticleSearchTermsService.new(self).generate
  end
end
