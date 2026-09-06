# Resolves the (credential, model_slug) pair to use at runtime for a given
# account/feature.
#
# The ONLY source of model identity is the database: platform_credential_models
# rows, written verbatim by Platform::Models::Importer from the provider's own
# live model list. config/llm.yml is a product catalog (which providers we
# support, display names, credit multipliers, what the dropdown offers) and is
# deliberately NOT consulted here — it lags behind what providers actually
# serve, so letting it name a model produced two failure modes in production:
#
#   * a valid, freshly synced slug rewritten into a catalog shorthand the
#     provider no longer serves (gemini-3-pro-preview was shut down by Google),
#   * a slug invented for an account that had never synced its models, which
#     then 404s at the provider and surfaces as a Captain handoff.
#
# Providers only classify models by KIND, so a Chatwoot feature maps to the
# kinds that can serve it (FEATURE_KINDS) rather than to a list of slugs.
#
# Returns nil when the account has no synced model to name. Callers fall back
# to their own legacy default (InstallationConfig / the global RubyLLM config);
# inventing a slug here is what this class exists to stop.
class Platform::Models::Resolver
  # Gemini/Claude chat models are stored as 'multimodal' by the importer
  # (Importer#classify_kind), so any chat-shaped feature must accept both or it
  # can never match a Gemini model.
  CHAT_KINDS = %w[chat multimodal].freeze

  FEATURE_KINDS = {
    'assistant' => CHAT_KINDS,
    'copilot' => CHAT_KINDS,
    'editor' => CHAT_KINDS,
    'label_suggestion' => CHAT_KINDS,
    'document_faq' => CHAT_KINDS,
    'audio_transcription' => %w[transcription multimodal],
    'help_center_search' => %w[embedding]
  }.freeze

  def self.resolve(account:, feature: nil, kind: nil, preferred_slug: nil, fallback_model: nil, allow_credential_only: false) # rubocop:disable Metrics/ParameterLists
    new(
      account: account,
      feature: feature,
      kind: kind,
      preferred_slug: preferred_slug,
      fallback_model: fallback_model,
      allow_credential_only: allow_credential_only
    ).resolve
  end

  # `fallback_model` is accepted for backwards compatibility and ignored: a
  # slug that does not come from the account's own credentials is exactly what
  # this resolver must not return.
  #
  # `allow_credential_only` is for callers that route by PROVIDER and carry
  # their own per-provider model default (Captain::Documents::PdfProvider).
  # They still get the account's credential — which is database data — when it
  # has no synced model, instead of silently falling back to another provider.
  # Callers that need a model slug leave it off and treat nil as "not
  # configured", because no honest slug exists for an account that never
  # synced its models.
  def initialize(account:, feature: nil, kind: nil, preferred_slug: nil, fallback_model: nil, allow_credential_only: false) # rubocop:disable Lint/UnusedMethodArgument,Metrics/ParameterLists
    @account = account
    @feature = feature.to_s.presence
    @kind = kind.to_s.presence
    @allow_credential_only = allow_credential_only
    # A stored preference is OUR value, so catalog shorthand applies to it.
    @preferred_slug = Llm::Models.canonical_model_slug(preferred_slug).presence
  end

  # Returns a Hash { credential:, model_slug:, source: } or nil.
  def resolve
    return nil if @account.nil?

    pair = resolve_pair
    return nil unless pair

    {
      credential: pair[:credential],
      model_slug: pair[:model_slug],
      source: pair[:source]
    }
  end

  private

  # Most specific first: the admin's explicit pick, then what the feature
  # needs, then an explicit kind, then anything enabled, then anything synced.
  def resolve_pair
    resolve_by_preferred_slug ||
      resolve_by_feature ||
      resolve_by_kind ||
      resolve_any_enabled ||
      resolve_synced_but_disabled ||
      resolve_credential_only
  end

  def resolve_by_preferred_slug
    return nil if @preferred_slug.blank?

    result_for(enabled_scope.find { |model| model.slug == @preferred_slug }, :preferred)
  end

  def resolve_by_feature
    return nil if @feature.blank?

    result_for(first_enabled_of_kinds(kinds_for_feature), :feature)
  end

  def resolve_by_kind
    return nil if @kind.blank?

    result_for(first_enabled_of_kinds(expand_kind(@kind)), :kind)
  end

  def resolve_any_enabled
    result_for(enabled_scope.first, :any_enabled)
  end

  # Last resort: the account synced models but enabled none of them. Better to
  # use a model the provider really serves than to name one it may not.
  # Preference order still honours the requested feature/kind.
  def resolve_synced_but_disabled
    kinds = kinds_for_feature.presence || expand_kind(@kind)
    result_for(first_synced_of_kinds(kinds) || synced_scope.first, :synced)
  end

  # Opt-in (see #initialize). The account has an active credential but nothing
  # synced, so the provider is known and the model is not.
  def resolve_credential_only
    return nil unless @allow_credential_only

    credential = supported_active_credentials.first || active_credentials.first
    return nil unless credential

    { credential: credential, model_slug: nil, source: :credential_only }
  end

  def result_for(model, source)
    return nil unless model

    { credential: credential_for(model), model_slug: Llm::Models.current_model_slug(model.slug), source: source }
  end

  # An explicit kind of 'chat' must also see the 'multimodal' rows Gemini and
  # Claude models are stored as.
  def expand_kind(kind)
    return [] if kind.blank?

    kind.to_s == 'chat' ? CHAT_KINDS : [kind.to_s]
  end

  def kinds_for_feature
    return [] if @feature.blank?

    FEATURE_KINDS.fetch(@feature, CHAT_KINDS)
  end

  # Ordered by the caller's kind preference, then deterministically by id, the
  # same way Platform::Models::CapabilityResolver picks a winner.
  def first_enabled_of_kinds(kinds)
    first_of_kinds(enabled_scope, kinds)
  end

  def first_synced_of_kinds(kinds)
    first_of_kinds(synced_scope, kinds)
  end

  # `scope` is an Array (see #scope_for). The credential ranking comes first:
  # an account with both a supported and a legacy OpenAI-compatible credential
  # must route through the supported one even when the legacy credential
  # happens to hold the kind listed first (a Gemini chat model is stored as
  # 'multimodal', so kind order alone would pick the legacy 'chat' row).
  def first_of_kinds(scope, kinds)
    return nil if kinds.blank?

    scope.select { |model| kinds.include?(model.kind) }
         .min_by { |model| [credential_rank(model), kinds.index(model.kind) || kinds.size, model.id] }
  end

  def credential_rank(model)
    ordered_credential_ids.index(model.credential_id) || ordered_credential_ids.size
  end

  def supported_active_credentials
    @supported_active_credentials ||= active_credentials.select do |credential|
      Llm::Config::SUPPORTED_RUNTIME_PROVIDERS.include?(normalized_provider(credential.provider))
    end
  end

  def active_credentials
    @active_credentials ||= @account.platform_credentials.active.to_a
  end

  def normalized_provider(provider)
    provider.to_s == 'google' ? 'gemini' : provider.to_s
  end

  # Credentials whose provider has a native runtime adapter come first, so an
  # account with both a supported and a legacy OpenAI-compatible credential
  # routes through the supported one.
  def ordered_credential_ids
    @ordered_credential_ids ||= begin
      supported_ids = supported_active_credentials.map(&:id)
      supported_ids + (active_credentials.map(&:id) - supported_ids)
    end
  end

  def synced_scope
    @synced_scope ||= scope_for(Platform::CredentialModel.all)
  end

  def enabled_scope
    @enabled_scope ||= scope_for(Platform::CredentialModel.enabled)
  end

  # Scoped to this account's active credentials (ordered_credential_ids is
  # built from them) and sorted so the winner is deterministic and prefers a
  # credential whose provider has a native runtime adapter.
  def scope_for(relation)
    ids = ordered_credential_ids
    return [] if ids.empty?

    relation.where(credential_id: ids)
            .to_a
            .sort_by { |model| [ids.index(model.credential_id) || ids.size, model.id] }
  end

  # Reuses the already-loaded credential objects instead of one query per model.
  def credential_for(model)
    credentials_by_id[model.credential_id]
  end

  def credentials_by_id
    @credentials_by_id ||= active_credentials.index_by(&:id)
  end
end
