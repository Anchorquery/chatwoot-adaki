FactoryBot.define do
  factory :adaki_campaign_approval, class: 'Adaki::CampaignApproval' do
    account
    campaign      { create(:campaign, account: account) }
    requested_by  { create(:user, account: account) }
    status        { 'pending' }
    requested_at  { Time.current }
  end
end
