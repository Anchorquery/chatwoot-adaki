FactoryBot.define do
  factory :adaki_absence, class: 'Adaki::Absence' do
    account
    user    { create(:user, account: account) }
    start_at { Time.current }
    end_at   { 1.day.from_now }
    status   { 'scheduled' }
    reason   { 'vacation' }
  end
end
