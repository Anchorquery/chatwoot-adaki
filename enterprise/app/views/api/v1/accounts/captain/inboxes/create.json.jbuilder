json.partial! 'api/v1/models/inbox', formats: [:json], resource: @captain_inbox.inbox
json.captain_inbox do
  json.id @captain_inbox.id
  json.settings @captain_inbox.settings || {}
  json.effective do
    json.continue_after_human_takeover @captain_inbox.continue_after_human_takeover?
    json.auto_handoff_enabled @captain_inbox.auto_handoff_enabled?
    json.auto_resolve_hours @captain_inbox.auto_resolve_hours_value
  end
end
