class Captain::Tools::FirecrawlParserJob < ApplicationJob
  queue_as :low

  def perform(assistant_id:, payload:, root_url: nil, crawl_mode: 'website', crawl_depth: nil)
    assistant = Captain::Assistant.find(assistant_id)
    metadata = payload[:metadata]

    canonical_url = normalize_link(metadata['url'])
    document = assistant.documents.find_or_initialize_by(
      external_link: canonical_url
    )

    document.update!(
      external_link: canonical_url,
      content: payload[:markdown],
      name: metadata['title'],
      status: :available,
      metadata: document.metadata.to_h.merge(
        'crawl_mode' => crawl_mode,
        'crawl_root_url' => root_url.presence || canonical_url,
        'crawl_depth' => crawl_depth
      ).compact,
      sync_status: :synced,
      last_synced_at: Time.current,
      last_sync_attempted_at: Time.current,
      last_sync_error_code: nil
    )
  rescue StandardError => e
    raise "Failed to parse FireCrawl data: #{e.message}"
  end

  private

  def normalize_link(raw_url)
    uri = URI.parse(raw_url.to_s)
    uri.fragment = nil
    uri.to_s.delete_suffix('/')
  rescue URI::InvalidURIError
    raw_url.to_s.delete_suffix('/')
  end
end
