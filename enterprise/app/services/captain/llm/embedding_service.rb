class Captain::Llm::EmbeddingService
  include Integrations::LlmInstrumentation

  class EmbeddingsError < StandardError; end

  # purpose: :write -> use the account's selected embedding model (new vectors).
  #          :search -> use the account's ACTIVE model (to match stored vectors).
  def initialize(account_id: nil, account: nil, purpose: :write)
    Llm::Config.initialize!
    @account = account || (account_id.present? ? Account.find_by(id: account_id) : nil)
    @account_id = @account&.id || account_id
    setup_target(purpose)
  end

  def self.embedding_model
    InstallationConfig.find_by(name: 'CAPTAIN_EMBEDDING_MODEL')&.value.presence || LlmConstants::DEFAULT_EMBEDDING_MODEL
  end

  # The model this service writes/queries with. Callers persist it as embedding_model.
  def model_name
    @embedding_model
  end

  def get_embedding(content, model: @embedding_model)
    return [] if content.blank?

    instrument_embedding_call(instrumentation_params(content, model)) do
      client = @llm_context || RubyLLM
      client.embed(content, **embed_options(model)).vectors
    end
  rescue RubyLLM::Error => e
    Rails.logger.error "Embedding API Error: #{e.message}"
    raise EmbeddingsError, "Failed to create an embedding: #{e.message}"
  end

  private

  def setup_target(purpose)
    target = resolve_target(purpose)
    @embedding_model = target&.model.presence || self.class.embedding_model
    @llm_context = target&.context
    @embedding_provider = target&.provider.presence || 'openai'
  end

  def resolve_target(purpose)
    return nil if @account.nil?

    if purpose == :search
      Captain::Embeddings::Manager.search_target(@account)
    else
      Captain::Embeddings::Manager.write_target(@account)
    end
  end

  # Force 1536 dims for Gemini (outputDimensionality) so vectors fit the shared
  # vector(1536) column. OpenAI's default model is already 1536, so we leave its
  # call untouched (no dimensions param) to preserve existing behavior exactly.
  def embed_options(model)
    options = { model: model }
    options[:dimensions] = Captain::Embeddings::Manager::DIMENSIONS if %w[gemini google].include?(@embedding_provider)
    options
  end

  def instrumentation_params(content, model)
    {
      span_name: 'llm.captain.embedding',
      model: model,
      input: content,
      feature_name: 'embedding',
      account_id: @account_id
    }
  end
end
