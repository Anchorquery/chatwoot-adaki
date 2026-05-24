FactoryBot.define do
  factory :adaki_audit_log_entry, class: 'Adaki::AuditLogEntry' do
    account
    action       { 'test.action' }
    payload      { {} }
    hash_chain   { SecureRandom.hex(32) }
    recorded_at  { Time.current }
  end
end
