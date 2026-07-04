json.payload do
  json.array! @audiences do |audience|
    json.id audience.id
    json.inbox_id audience.inbox_id
    json.inbox_name audience.inbox.name
    json.group_jids audience.group_jids
    json.label_titles audience.label_titles
  end
end

json.meta do
  json.total_count @audiences.size
  json.page 1
end
