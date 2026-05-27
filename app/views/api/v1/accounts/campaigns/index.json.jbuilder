json.meta do
  json.total_count @total_count
  json.current_page @current_page
  json.per_page @per_page
end

json.payload do
  json.array! @campaigns do |campaign|
    json.partial! 'api/v1/models/campaign', formats: [:json], resource: campaign
  end
end
