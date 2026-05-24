FactoryBot.define do
  factory :adaki_whatsapp_tier_snapshot, class: 'Adaki::WhatsappTierSnapshot' do
    channel_whatsapp        { create(:channel_whatsapp) }
    messaging_limit_tier    { 1 }
    max_daily_conversations { 1_000 }
    conversations_sent_24h  { 100 }
    quality_rating          { 'GREEN' }
    status                  { 'CONNECTED' }
    raw_payload             { {} }
    captured_at             { Time.current }
  end
end
