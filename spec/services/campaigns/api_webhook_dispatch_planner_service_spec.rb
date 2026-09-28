require 'rails_helper'

RSpec.describe Campaigns::ApiWebhookDispatchPlannerService do
  let(:account) { create(:account) }
  let(:inbox) { create(:inbox, account: account, channel: create(:channel_api, account: account)) }
  let(:campaign) { create(:campaign, account: account, inbox: inbox, delivery_settings: delivery_settings, delivery_state: delivery_state) }
  let(:conversation) { create(:conversation, account: account, inbox: inbox, campaign: campaign) }
  let(:message) { create(:message, account: account, inbox: inbox, conversation: conversation) }
  let(:delivery_settings) { {} }
  let(:delivery_state) { {} }

  def plan
    described_class.new(message: message, inbox: inbox).perform
  end

  it 'schedules the message and records the dispatch in the campaign state' do
    freeze_time do
      expect(plan).to eq(Time.current)
      expect(campaign.reload.delivery_state['webhook_daily_sent_count']).to eq(1)
    end
  end

  context 'when the daily limit is reached' do
    let(:delivery_settings) { { 'max_daily_messages' => 1 } }
    let(:delivery_state) { { 'webhook_last_sent_on' => Time.zone.today.to_s, 'webhook_daily_sent_count' => 1 } }

    it 'returns nil and keeps the campaign paused' do
      expect(plan).to be_nil

      campaign.reload
      expect(campaign).to be_paused
      expect(campaign.delivery_state['errors'].last['system']).to eq('Daily delivery limit reached')
    end
  end
end
