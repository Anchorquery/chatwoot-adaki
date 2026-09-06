class Captain::Llm::EmbeddingService
  include Integrations::LlmInstrumentation

  class EmbeddingsError < StandardError; end

  # purpose: :write -> use the account's selected embedding model (new vectors).
  #          :search -> use the account's ACTIVE model (to match stored vectors).
  # Search queries repeat a lot ("precio", "catálogo", the retry replay of
  # the same turn, a scenario re-checking what the orchestrator just looked
  # up) and each one is a provider round-trip the customer waits on. Vectors
  # for the same text+model are deterministic, so they are cached. :write
  # embeddings (FAQ content) are one-off and skip the cache.
  SEARCH_CACHE_TTL = 24.hours
  SEARCH_CACHE_PREFIX = 'captain:embedding:search'.freeze

  def initialize(account_id: nil, account: nil, purpose: :write)
    Llm::Config.initialize!
    @account = account || (account_id.present? ? Account.find_by(id: account_id) : nil)
    @account_id = @account&.id || account_id
    @purpose = purpose
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

    cached = cached_search_embedding(content, model)
    return cached if cached

    vectors = instrument_embedding_call(instrumentation_params(content, model)) do
      client = @llm_context || RubyLLM
      client.embed(content, **embed_options(model)).vectors
    end
    remember_search_embedding(content, model, vectors)
    vectors
  rescue RubyLLM::Error => e
    Rails.logger.error "Embedding API Error: #{e.message}"
    raise EmbeddingsError, "Failed to create an embedding: #{e.message}"
  end

  private

  def search_cache_key(content, model)
    return nil unless @purpose == :search

    normalized = content.to_s.strip.downcase.squeeze(' ')
    "#{SEARCH_CACHE_PREFIX}:#{Digest::SHA256.hexdigest("#{@embedding_provider}|#{model}|#{normalized}")}"
  end

  # Redis being down must never break a search — it just costs the provider call.
  def cached_search_embedding(content, model)
    key = search_cache_key(content, model)
    return nil unless key

    raw = ::Redis::Alfred.get(key)
    raw.present? ? JSON.parse(raw) : nil
  rescue StandardError => e
    Rails.logger.warn "[Captain] embedding cache read failed: #{e.class}: #{e.message}"
    nil
  end

  def remember_search_embedding(content, model, vectors)
    key = search_cache_key(content, model)
    return unless key && vectors.present?

    ::Redis::Alfred.setex(key, vectors.to_json, SEARCH_CACHE_TTL.to_i)
  rescue StandardError => e
    Rails.logger.warn "[Captain] embedding cache write failed: #{e.class}: #{e.message}"
  end

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
    if %w[gemini google].include?(@embedding_provider)
      options[:dimensions] = Captain::Embeddings::Manager::DIMENSIONS
      # Force the Gemini (generativelanguage) provider. Gemini embedding slugs
      # (e.g. gemini-embedding-001) also exist under 'vertexai' in RubyLLM's
      # registry; without an explicit provider it may route to VertexAI, which
      # needs GCP project/location we don't have (we authenticate with an api key).
      options[:provider] = 'gemini'
      options[:assume_model_exists] = true
    end
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
