# Single source of truth for an account's embedding provider/model.
#
# Two providers (OpenAI and Google) coexist in the same vector(1536) tables, so
# vectors are tagged with their model and never compared across models. We track
# two pointers per account:
#
#   * WRITE model  — the account's currently selected embedding model (the one
#     new vectors are generated with). Resolved from the enabled embedding
#     CredentialModel, defaulting to OpenAI text-embedding-3-small.
#   * ACTIVE model — the model the stored vectors currently use and that search
#     must filter by. Stored on the account (internal_attributes) and lags the
#     write model during a provider switch until ReindexJob finishes and flips it.
#
# In steady state write == active. They diverge only between an admin switching
# providers and the reindex completing.
module Captain::Embeddings
  module Manager
    module_function

    DEFAULT_MODEL = LlmConstants::DEFAULT_EMBEDDING_MODEL # 'text-embedding-3-small'
    DIMENSIONS = 1536
    ACTIVE_KEY = 'captain_active_embedding_model'.freeze
    # Embedding model for the Gemini (generativelanguage) API. Must be a slug
    # RubyLLM maps to the 'gemini' provider — NOT 'text-embedding-004', which the
    # registry only lists under 'vertexai' (needs GCP project/location, not an
    # api key) and is natively 768-dim (can't produce the 1536-dim column).
    # gemini-embedding-001 routes to the Gemini API and truncates to 1536 dims.
    GEMINI_FALLBACK_MODEL = 'gemini-embedding-001'.freeze

    Target = Struct.new(:model, :context, :provider, keyword_init: true)

    # ---- WRITE side (new embeddings) -------------------------------------

    def write_target(account)
      resolved = resolved_embedding(account)
      return default_target if resolved.nil?

      Target.new(model: resolved.model_slug, context: resolved.context, provider: resolved.provider)
    end

    def write_model(account)
      write_target(account).model
    end

    # ---- ACTIVE side (search) --------------------------------------------

    def active_model(account)
      return DEFAULT_MODEL if account.nil?

      account.internal_attributes[ACTIVE_KEY].presence || DEFAULT_MODEL
    end

    # Target (model + matching credential context) for the ACTIVE model, used to
    # embed search queries in the same space as the stored vectors.
    #
    # When ACTIVE_KEY has never been explicitly set (no ReindexJob has run yet),
    # we mirror write_target so search stays in the same embedding space as new
    # writes. This prevents the search path from falling back to global OpenAI on
    # accounts where write_target already resolved to Gemini.
    def search_target(account)
      return write_target(account) if account && !account.internal_attributes.key?(ACTIVE_KEY)

      model = active_model(account)
      credential_model = credential_model_for(account, model)
      # Resolved once and shared by context/provider lookups below, instead of
      # each re-running the full resolved_embedding fallback chain (and its
      # credential queries) independently.
      fallback = credential_model.nil? && model != DEFAULT_MODEL ? resolved_embedding(account) : nil
      fallback = nil if fallback && fallback.model_slug != model

      Target.new(
        model: model,
        context: model_context(account, model, credential_model, fallback),
        provider: model_provider(model, credential_model, fallback)
      )
    end

    def set_active!(account, model)
      account.update_column(:internal_attributes, account.internal_attributes.merge(ACTIVE_KEY => model))
    end

    # Scopes a vector relation to the account's active embedding model.
    #
    # When ACTIVE_KEY is not set we use write_model to mirror write_target, so
    # search filters by the same model being written (e.g. Gemini gemini-embedding-001).
    # For the OpenAI default we also include NULL rows (legacy untagged vectors).
    # For any other model we filter strictly to avoid cross-provider comparison.
    def scope_to_active(relation, account)
      return relation if account.nil?

      model = if account.internal_attributes.key?(ACTIVE_KEY)
                active_model(account)
              else
                write_model(account)
              end

      if model == DEFAULT_MODEL
        relation.where('embedding_model = ? OR embedding_model IS NULL', model)
      else
        relation.where(embedding_model: model)
      end
    end

    # ---- Transition ------------------------------------------------------

    # Enqueues a reindex when the selected (write) model diverges from the active
    # one. Idempotent: the job re-checks and no-ops if nothing changed.
    def reconcile!(account)
      return if account.nil?

      target = write_model(account)
      current = active_model(account)
      return if target == current

      # Pin ACTIVE_KEY to the pre-switch model before enqueuing the reindex. If
      # it were left unset, scope_to_active/search_target would immediately
      # mirror write_model (the new provider) and search would go blank on
      # vectors that haven't been reindexed yet.
      set_active!(account, current) unless account.internal_attributes.key?(ACTIVE_KEY)

      Captain::Embeddings::ReindexJob.perform_later(account.id, target)
    end

    # ---- Helpers ---------------------------------------------------------

    def resolved_embedding(account)
      return nil if account.nil?

      # 1. The model the admin explicitly picked in Captain settings wins.
      explicit = explicit_embedding_target(account)
      return explicit if explicit

      # 2. An enabled embedding CredentialModel (synced + toggled in the UI).
      result = Platform::Models::CapabilityResolver.resolve(account: account, kinds: %w[embedding])
      return result if result

      # 3. No explicit model — fall back to Gemini's embedding model when the
      # account has an active Google credential, avoiding the global OpenAI
      # fallback for accounts that only have Gemini configured.
      gemini_fallback_target(account)
    end

    # Honors captain_models['help_center_search']. Reads the raw stored value
    # (not the YAML-default-filled accessor) so the default stays "auto" until an
    # admin picks one. Resolves the credential by enabled CredentialModel first,
    # then by the model's provider — so a catalog option like gemini-embedding-001
    # works even before the model is synced/enabled.
    def explicit_embedding_target(account)
      models = account.try(:captain_models)
      selected = models.is_a?(Hash) ? models['help_center_search'].presence : nil
      return nil unless selected

      credential_model = credential_model_for(account, selected)
      return embedding_result(credential_model.credential, credential_model.slug) if credential_model

      provider = Llm::Models.models.dig(selected, 'provider').to_s.presence
      # An explicit OpenAI pick must win outright — return a Result-shaped
      # default instead of nil, otherwise resolved_embedding falls through to
      # CapabilityResolver/gemini_fallback_target and a stale Gemini
      # CredentialModel silently overrides the admin's OpenAI choice.
      return default_result if provider.blank? || provider == 'openai'

      credential = Platform::Credential.active
                                       .where(account_id: account.id, provider: provider_aliases(provider))
                                       .first
      credential && embedding_result(credential, selected)
    end

    def gemini_fallback_target(account)
      # Credentials created from the UI store provider 'gemini' (llm.yml key);
      # older rows may carry 'google', so match both.
      gemini_cred = Platform::Credential.active
                                        .where(account_id: account.id, provider: %w[google gemini])
                                        .first
      gemini_cred && embedding_result(gemini_cred, GEMINI_FALLBACK_MODEL)
    end

    def embedding_result(credential, model_slug)
      Platform::Models::CapabilityResolver::Result.new(
        credential: credential,
        model_slug: model_slug,
        provider: credential.provider.to_s,
        context: Llm::Config.context_for_credential(credential)
      )
    end

    def provider_aliases(provider)
      %w[google gemini].include?(provider) ? %w[google gemini] : [provider]
    end

    # Result-shaped (model_slug/provider/context) equivalent of default_target,
    # for early-returning out of resolved_embedding's fallback chain.
    def default_result
      Platform::Models::CapabilityResolver::Result.new(credential: nil, model_slug: DEFAULT_MODEL, provider: 'openai', context: nil)
    end

    def default_target
      Target.new(model: DEFAULT_MODEL, context: nil, provider: 'openai')
    end

    # Context for an arbitrary model slug (even if its CredentialModel was since
    # disabled — relevant for the lagging active model during a switch). The
    # OpenAI default uses the global RubyLLM config (nil context). credential_model
    # and fallback are pre-resolved once by the caller (search_target) to avoid
    # re-running the resolved_embedding chain per accessor.
    def model_context(account, model, credential_model, fallback)
      return nil if account.nil? || model == DEFAULT_MODEL
      return Llm::Config.context_for_credential(credential_model.credential) if credential_model

      # Fallback embedding model (no explicit CredentialModel): reuse the same
      # Gemini-credential context the write path resolved, so the search query
      # embeds with the same key/provider the stored vectors were written with.
      fallback&.context
    end

    def model_provider(model, credential_model, fallback)
      return 'openai' if model == DEFAULT_MODEL

      cm_provider = credential_model&.credential&.provider.to_s.presence
      return cm_provider if cm_provider
      return fallback.provider.to_s if fallback

      Llm::Models.models.dig(model, 'provider').presence || 'openai'
    end

    def credential_model_for(account, model)
      Platform::CredentialModel
        .joins(:credential)
        .where(platform_credentials: { account_id: account.id }, slug: model)
        .merge(Platform::Credential.active)
        .first
    end
  end
end
