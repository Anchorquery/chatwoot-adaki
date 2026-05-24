FactoryBot.define do
  factory :adaki_captain_usage, class: 'Adaki::CaptainUsage' do
    account
    period         { Date.current.beginning_of_month }
    request_count  { 0 }
    input_tokens   { 0 }
    output_tokens  { 0 }
  end
end
