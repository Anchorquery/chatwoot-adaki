# Decides which provider handles a document's PDF processing/FAQ generation.
#
# OpenAI (default) uses the Files API: upload once (openai_file_id) and reference
# it across paginated chat calls. Gemini has no Files API in our stack — RubyLLM
# sends files inline (base64) — so Gemini PDFs skip the upload step and are read
# inline at FAQ-generation time. PDFs are capped at 10 MB, well within Gemini's
# inline request limit.
module Captain::Documents::PdfProvider
  module_function

  # Returns 'gemini' when the account's enabled LLM model is Gemini, else 'openai'.
  def provider_for(document)
    account = document&.account
    return 'openai' if account.nil?

    resolved = Platform::Models::CapabilityResolver.resolve(account: account, kinds: %w[multimodal chat])
    resolved&.provider == 'gemini' ? 'gemini' : 'openai'
  end

  def gemini?(document)
    provider_for(document) == 'gemini'
  end
end
