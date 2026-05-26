json.account_id resource.account_id
json.assistant do
  json.partial! 'api/v1/models/captain/assistant', formats: [:json], resource: resource.assistant
end
json.content resource.content
json.content_type resource.content_type
json.crawl_pages_count resource.crawl_pages_count
json.crawl_expected_pages_count resource.crawl_expected_pages_count
json.crawl_progress_percent resource.crawl_progress_percent
json.created_at resource.created_at.to_i
json.external_link resource.external_link
json.display_url resource.display_url
json.metadata resource.metadata
json.file_size resource.file_size
json.pdf_document resource.pdf_document?
json.id resource.id
json.name resource.name
json.status resource.status
json.sync_status resource.sync_status
json.sync_in_progress resource.sync_in_progress?
json.last_synced_at resource.last_synced_at&.to_i
json.last_sync_attempted_at resource.last_sync_attempted_at&.to_i
json.last_sync_error_code resource.last_sync_error_code
json.updated_at resource.updated_at.to_i
