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
    def search_target(account)
      model = active_model(account)
      Target.new(model: model, context: context_for_model(account, model), provider: provider_for_model(account, model))
    end

    def set_active!(account, model)
      account.update_column(:internal_attributes, account.internal_attributes.merge(ACTIVE_KEY => model))
    end

    # Scopes a vector relation to the account's active embedding model.
    #
    # For the OpenAI default model we also include untagged (NULL) rows: legacy
    # vectors created before tagging — and any OpenAI-only install — are OpenAI
    # vectors, so behavior is unchanged. For a non-default (e.g. Gemini) active
    # model we filter strictly so OpenAI vectors are never mixed in.
    def scope_to_active(relation, account)
      return relation if account.nil?

      model = active_model(account)
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
      return if target == active_model(account)

      Captain::Embeddings::ReindexJob.perform_later(account.id, target)
    end

    # ---- Helpers ---------------------------------------------------------

    def resolved_embedding(account)
      return nil if account.nil?

      result = Platform::Models::CapabilityResolver.resolve(account: account, kinds: %w[embedding])
      return result if result

      # No explicit embedding CredentialModel — fall back to Gemini's embedding
      # model when the account has an active Google credential, avoiding the
      # global OpenAI fallback for accounts that only have Gemini configured.
      gemini_cred = Platform::Credential.active
                                         .where(account_id: account.id, provider: 'google')
                                         .first
      return nil unless gemini_cred

      Platform::Models::CapabilityResolver::Result.new(
        credential: gemini_cred,
        model_slug: 'text-embedding-004',
        provider: 'google',
        context: Llm::Config.context_for_credential(gemini_cred)
      )
    end

    def default_target
      Target.new(model: DEFAULT_MODEL, context: nil, provider: 'openai')
    end

    # Context for an arbitrary model slug (even if its CredentialModel was since
    # disabled — relevant for the lagging active model during a switch). The
    # OpenAI default uses the global RubyLLM config (nil context).
    def context_for_model(account, model)
      return nil if account.nil? || model == DEFAULT_MODEL

      credential_model = credential_model_for(account, model)
      credential_model && Llm::Config.context_for_credential(credential_model.credential)
    end

    def provider_for_model(account, model)
      return 'openai' if model == DEFAULT_MODEL

      credential_model_for(account, model)&.credential&.provider.to_s.presence ||
        Llm::Models.models.dig(model, 'provider').presence ||
        'openai'
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
