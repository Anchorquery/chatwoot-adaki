json.payload do
  json.array! @documents do |document|
    json.partial! 'api/v1/models/captain/document', formats: [:json], resource: document
  end
end

json.meta do
  json.total_count @documents_count
  json.page @current_page
  json.web_count @web_documents_count
  json.pdf_count @pdf_documents_count
  json.syncing_count @syncing_documents_count
  json.failed_count @failed_documents_count
  json.stale_count @stale_documents_count
  json.website_crawl_pages_count @website_crawl_pages_count
  json.website_crawl_count @website_crawl_count
  json.sync_interval_hours @sync_interval_hours if @sync_interval_hours.present?
end
