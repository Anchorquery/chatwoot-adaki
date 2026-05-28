json.payload do
  json.array! @captain_inboxes do |ci|
    json.partial! 'api/v1/models/inbox', formats: [:json], resource: ci.inbox
    json.captain_inbox do
      json.id ci.id
      json.settings ci.settings || {}
      json.effective do
        json.continue_after_human_takeover ci.continue_after_human_takeover?
        json.auto_handoff_enabled ci.auto_handoff_enabled?
        json.auto_resolve_hours ci.auto_resolve_hours_value
      end
    end
  end
end

json.meta do
  json.total_count @captain_inboxes.size
  json.page 1
end
