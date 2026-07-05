FactoryBot.define do
  factory :captain_assistant, class: 'Captain::Assistant' do
    sequence(:name) { |n| "Assistant #{n}" }
    description { 'Test description' }
    config { { 'autopilot_enabled' => true } }
    association :account
  end
end
