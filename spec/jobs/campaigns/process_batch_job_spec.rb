require 'rails_helper'

RSpec.describe Campaigns::ProcessBatchJob do
  let(:account) { create(:account) }
  let(:inbox) { create(:inbox, account: account, channel: create(:channel_api, account: account)) }
  let(:sender) { create(:user, account: account, role: :administrator) }
  let(:known_contact) { create(:contact, account: account, phone_number: '+34600000001') }
  let(:cold_contact) { create(:contact, account: account, phone_number: '+34600000002') }
  let(:campaign) do
    create(:campaign, account: account, inbox: inbox, sender: sender, campaign_status: :running,
                      delivery_settings: { 'batch_size' => 10 },
                      delivery_state: { 'contact_ids' => [known_contact.id, cold_contact.id], 'total_contacts' => 2,
                                        'processed_index' => 0, 'recipients' => {} })
  end

  before { create(:contact_inbox, contact: known_contact, inbox: inbox) }

  it 'only writes to contacts that already have a conversation with the inbox' do
    described_class.perform_now(campaign)

    recipients = campaign.reload.delivery_state['recipients']
    expect(recipients[known_contact.id.to_s]['status']).to eq('sent')
    expect(recipients[cold_contact.id.to_s]['status']).to eq('skipped')
    expect(recipients[cold_contact.id.to_s]['error']).to eq(described_class::SKIPPED_REASON)
  end

  it 'does not link contacts that never wrote to the inbox' do
    expect { described_class.perform_now(campaign) }.not_to(change { inbox.contact_inboxes.where(contact: cold_contact).count })
    expect(campaign.conversations.where(contact: cold_contact)).to be_empty
  end
end
