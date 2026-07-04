class Captain::Documents::CrawlJob < ApplicationJob
  queue_as :low

  def perform(document)
    if document.pdf_document?
      perform_pdf_processing(document)
    elsif InstallationConfig.find_by(name: 'CAPTAIN_FIRECRAWL_API_KEY')&.value.present?
      perform_firecrawl_crawl(document)
    else
      perform_simple_crawl(document)
    end
  end

  private

  include Captain::FirecrawlHelper

  def perform_pdf_processing(document)
    # Gemini reads the PDF inline during FAQ generation (no Files API upload),
    # so skip the OpenAI-only upload step for Gemini accounts — instantiating the
    # legacy OpenAI client would otherwise require an OpenAI key.
    Captain::Llm::PdfProcessingService.new(document).process unless Captain::Documents::PdfProvider.gemini?(document)
    document.update!(status: :available)
  rescue StandardError => e
    Rails.logger.error I18n.t('captain.documents.pdf_processing_failed', document_id: document.id, error: e.message)
    raise # Re-raise to let job framework handle retry logic
  end

  def perform_simple_crawl(document)
    available_limit = document.account.usage_limits[:captain][:documents][:current_available]
    return if available_limit.to_i <= 0

    page_links = Captain::Tools::SimplePageCrawlService.new(document.external_link).page_links
    requested_limit = document.crawl_depth.to_i.positive? ? document.crawl_depth.to_i : page_links.size
    crawl_limit = [requested_limit, available_limit.to_i].min
    selected_page_links = crawl_limit ? page_links.first(crawl_limit) : page_links

    selected_page_links.each do |page_link|
      Captain::Tools::SimplePageCrawlParserJob.perform_later(
        assistant_id: document.assistant_id,
        page_link: page_link,
        crawl_root_url: document.external_link,
        crawl_mode: document.crawl_mode.presence || 'website',
        crawl_depth: crawl_limit
      )
    end

    Captain::Tools::SimplePageCrawlParserJob.perform_later(
      assistant_id: document.assistant_id,
      page_link: document.external_link,
      crawl_root_url: document.external_link,
      crawl_mode: document.crawl_mode.presence || 'website',
      crawl_depth: crawl_limit
    )
  end

  def perform_firecrawl_crawl(document)
    captain_usage_limits = document.account.usage_limits[:captain] || {}
    document_limit = captain_usage_limits[:documents] || {}
    available_limit = document_limit[:current_available].to_i
    return if available_limit <= 0

    requested_limit = document.crawl_depth.to_i.positive? ? document.crawl_depth.to_i : available_limit
    crawl_limit = [requested_limit, available_limit, 500].min

    Captain::Tools::FirecrawlService
      .new
      .perform(
        document.external_link,
        firecrawl_webhook_url(document, crawl_limit),
        crawl_limit
      )
  end

  def firecrawl_webhook_url(document, crawl_limit)
    webhook_url = Rails.application.routes.url_helpers.enterprise_webhooks_firecrawl_url

    "#{webhook_url}?assistant_id=#{document.assistant_id}&token=#{generate_firecrawl_token(document.assistant_id,
                                                                                           document.account_id)}&root_url=#{URI.encode_www_form_component(document.external_link)}&crawl_depth=#{crawl_limit}"
  end
end
