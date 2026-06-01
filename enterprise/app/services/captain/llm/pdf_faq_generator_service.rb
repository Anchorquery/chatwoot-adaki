# Generates FAQs from a PDF document using a provider that reads files inline
# (Gemini). The PDF (capped at 10 MB) is sent inline via RubyLLM rather than
# through the OpenAI Files API, so no upload/file_id step is needed. Gemini's
# large context lets us process the whole document in a single pass instead of
# the page-chunked flow OpenAI uses (Captain::Llm::PaginatedFaqGeneratorService).
#
# Provider-aware via Llm::BaseAiService: resolves the account's multimodal model
# + credential context. Selected by Captain::Documents::PdfProvider.
class Captain::Llm::PdfFaqGeneratorService < Llm::BaseAiService
  include Integrations::LlmInstrumentation

  USER_PROMPT = 'Read the attached PDF document in full and generate the FAQs as instructed.'.freeze

  def initialize(document, options = {})
    @document = document
    @language = options[:language].presence || document&.account&.locale_english_name || 'english'
    # Set ivars before super() so setup_model resolves the account's provider.
    super()
  end

  def generate
    return [] if @document.blank? || !@document.pdf_file.attached?

    response = instrument_llm_call(instrumentation_params) do
      chat
        .with_params(**json_mode_params)
        .with_instructions(system_prompt)
        .ask(USER_PROMPT, with: @document.pdf_file)
    end

    parse_faqs(response.content)
  rescue StandardError => e
    Rails.logger.error "[Captain][PdfFaqGenerator] document=#{@document&.id}: #{e.class}: #{e.message}"
    []
  end

  private

  def resolver_account
    @document&.account
  end

  # PDF understanding needs a vision/multimodal model.
  def resolver_kind
    'multimodal'
  end

  def system_prompt
    Captain::Llm::SystemPromptsService.faq_generator(@language)
  end

  def parse_faqs(content)
    JSON.parse(sanitize_json_response(content)).fetch('faqs', [])
  rescue JSON::ParserError, TypeError => e
    Rails.logger.error "[Captain][PdfFaqGenerator] parse error document=#{@document&.id}: #{e.message}"
    []
  end

  def instrumentation_params
    {
      span_name: 'llm.captain.pdf_faq_generation',
      account_id: @document&.account_id,
      feature_name: 'pdf_faq_generation',
      model: @model,
      messages: [{ role: 'system', content: system_prompt }, { role: 'user', content: USER_PROMPT }],
      metadata: (@document.respond_to?(:to_llm_metadata) ? @document.to_llm_metadata : {})
    }
  end
end
