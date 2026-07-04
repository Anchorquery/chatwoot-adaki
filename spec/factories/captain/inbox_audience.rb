FactoryBot.define do
  factory :captain_inbox_audience, class: 'CaptainInboxAudience' do
    association :captain_assistant, factory: :captain_assistant
    association :inbox
    group_jids { ['1203630000000'] }
    label_titles { [] }
  end
end
