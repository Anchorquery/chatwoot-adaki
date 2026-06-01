class Captain::Documents::ResponseBuilderJob < ApplicationJob
  queue_as :low

  def perform(document, options = {})
    reset_previous_responses(document)

    faqs = generate_faqs(document, options)
    create_responses_from_faqs(faqs, document)
  end

  private

  def generate_faqs(document, options)
    if gemini_pdf?(document)
      generate_gemini_pdf_faqs(document)
    elsif should_use_pagination?(document)
      generate_paginated_faqs(document, options)
    else
      generate_standard_faqs(document)
    end
  end

  def gemini_pdf?(document)
    document.pdf_document? && Captain::Documents::PdfProvider.gemini?(document)
  end

  # Gemini reads the PDF inline in a single pass (no Files API / pagination).
  def generate_gemini_pdf_faqs(document)
    Captain::Llm::PdfFaqGeneratorService.new(
      document,
      language: document.account.locale_english_name
    ).generate
  end

  def generate_paginated_faqs(document, options)
    service = build_paginated_service(document, options)
    faqs = service.generate
    store_paginated_metadata(document, service)
    faqs
  end

  def generate_standard_faqs(document)
    Captain::Llm::FaqGeneratorService.new(document: document).generate
  end

  def build_paginated_service(document, options)
    Captain::Llm::PaginatedFaqGeneratorService.new(
      document,
      pages_per_chunk: options[:pages_per_chunk],
      max_pages: options[:max_pages],
      language: document.account.locale_english_name
    )
  end

  def store_paginated_metadata(document, service)
    document.update!(
      metadata: (document.metadata || {}).merge(
        'faq_generation' => {
          'method' => 'paginated',
          'pages_processed' => service.total_pages_processed,
          'iterations' => service.iterations_completed,
          'timestamp' => Time.current.iso8601
        }
      )
    )
  end

  def create_responses_from_faqs(faqs, document)
    faqs.each { |faq| create_response(faq, document) }
  end

  def should_use_pagination?(document)
    # Auto-detect when to use pagination
    # For now, use pagination for PDFs with OpenAI file ID
    document.pdf_document? && document.openai_file_id.present?
  end

  def reset_previous_responses(response_document)
    response_document.responses.where(edited: false).destroy_all
  end

  def create_response(faq, document)
    document.responses.create!(
      question: faq['question'],
      answer: faq['answer'],
      assistant: document.assistant,
      documentable: document
    )
  rescue ActiveRecord::RecordInvalid => e
    Rails.logger.error I18n.t('captain.documents.response_creation_error', error: e.message)
  end
end
