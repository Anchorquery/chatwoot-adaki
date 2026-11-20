require 'rails_helper'

RSpec.describe Campaigns::ResumeService do
  let(:account) { create(:account) }
  let(:inbox) { create(:inbox, account: account, channel: create(:channel_api, account: account)) }
  # 1 enviado, 2 fallido reintentable, 3 y 4 sin procesar.
  let(:campaign) do
    create(:campaign, account: account, inbox: inbox, campaign_status: :paused,
                      delivery_state: { 'contact_ids' => [1, 2, 3, 4], 'processed_index' => 2,
                                        'recipients' => { '1' => { 'status' => 'sent' },
                                                          '2' => { 'status' => 'failed', 'error' => 'timeout' } } })
  end

  def resume(scope)
    described_class.new(campaign: campaign, scope: scope).perform
  end

  it 'sends to failed and pending by default' do
    result = resume(nil)

    expect([result.failed_count, result.pending_count]).to eq([1, 2])
    expect(campaign.reload.delivery_state).to include('contact_ids' => [1, 2, 3, 4], 'processed_index' => 1,
                                                      'deferred_contact_ids' => [])
  end

  it 'only retries failures and keeps the pending ones for later' do
    result = resume('failed')

    expect([result.failed_count, result.pending_count]).to eq([1, 0])
    state = campaign.reload.delivery_state
    expect(state).to include('contact_ids' => [1, 2], 'deferred_contact_ids' => [3, 4], 'total_contacts' => 4)
    expect(described_class.pending_ids(state)).to contain_exactly(2, 3, 4)
  end

  it 'only sends to pending ones and leaves failures as they are' do
    result = resume('pending')

    expect([result.failed_count, result.pending_count]).to eq([0, 2])
    state = campaign.reload.delivery_state
    expect(state['contact_ids']).to eq([1, 2, 3, 4])
    expect(state['recipients']['2']['status']).to eq('failed')
  end

  it 'brings deferred recipients back on the next send' do
    resume('failed')
    campaign.update!(campaign_status: :paused,
                     delivery_state: campaign.delivery_state.merge('processed_index' => 2,
                                                                   'recipients' => { '1' => { 'status' => 'sent' },
                                                                                     '2' => { 'status' => 'sent' } }))

    expect(resume('pending').pending_count).to eq(2)
    expect(campaign.reload.delivery_state).to include('contact_ids' => [1, 2, 3, 4], 'deferred_contact_ids' => [])
  end

  it 'refuses a running campaign' do
    campaign.update!(campaign_status: :running)

    expect(resume(nil).error).to eq('Campaign is already running')
  end
end
