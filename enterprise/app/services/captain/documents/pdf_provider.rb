# Decides which provider/model handles a document's PDF processing/FAQ generation.
#
# OpenAI (default) uses the Files API: upload once (openai_file_id) and reference
# it across paginated chat calls. Gemini has no Files API in our stack — RubyLLM
# sends files inline (base64) — so Gemini PDFs skip the upload step and are read
# inline at FAQ-generation time. PDFs are capped at 10 MB, well within Gemini's
# inline request limit.
#
# Resolution honors the account's explicit choice from Captain settings
# (captain_models['document_faq']) when set, otherwise auto-resolves to the
# account's active credential — so an account with only a Gemini key (no OpenAI
# key) is never routed to the OpenAI Files API it cannot authenticate against.
#
# This is the SINGLE source of truth shared by the dispatcher, the Gemini Files
# upload (Captain::Documents::GeminiFileBackend), the OpenAI paginated generator,
# and the Gemini inline generator (Captain::Llm::PdfFaqGeneratorService) so they
# never disagree on provider/credential/model.
module Captain::Documents::PdfProvider
  module_function

  # Captain feature key backing the model selector in /settings/captain.
  FEATURE = 'document_faq'.freeze

  # Capability kind PDF understanding needs (vision). Used as the resolution
  # fallback when no explicit model is selected and no feature model is enabled.
  RESOLVER_KIND = 'multimodal'.freeze

  # Returns 'gemini' when the resolved credential is Gemini, else 'openai'.
  def provider_for(document)
    normalize_provider(resolved_credential(document)&.provider)
  end

  def gemini?(document)
    provider_for(document) == 'gemini'
  end

  # The credential PDF processing will actually use.
  def resolved_credential(document)
    resolution(document)&.dig(:credential)
  end

  # The model slug PDF generation will use. Nil when the account has no usable
  # credential (legacy installs then fall back to LlmConstants::PDF_PROCESSING_MODEL
  # / the global InstallationConfig OpenAI key).
  def resolved_model(document)
    resolution(document)&.dig(:model_slug)
  end

  # { credential:, model_slug:, source: } or nil. Memoized per call site is not
  # needed; callers hit this at most a couple of times per job.
  def resolution(document)
    account = document&.account
    return nil if account.nil?

    Platform::Models::Resolver.resolve(
      account: account,
      feature: FEATURE,
      preferred_slug: selected_model(account),
      kind: RESOLVER_KIND
    )
  end

  # The model the admin explicitly picked in Captain settings, or nil. Reading the
  # raw stored value (not captain_*_model, which fills in a YAML default) keeps the
  # default behavior "auto by active provider" until an explicit choice is made.
  def selected_model(account)
    models = account.try(:captain_models)
    models.is_a?(Hash) ? models['document_faq'].presence : nil
  end

  # Credentials are stored with provider 'gemini' (the llm.yml key); some older
  # rows carry 'google'. Treat both as Gemini; anything else (or nil) routes to
  # the OpenAI Files API path.
  def normalize_provider(provider)
    provider = provider.to_s
    return 'gemini' if %w[gemini google].include?(provider)

    provider.presence || 'openai'
  end
end
