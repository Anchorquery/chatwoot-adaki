require 'rails_helper'

RSpec.describe Campaigns::ProcessBatchJob do
  let(:account) { create(:account) }
  let(:inbox) { create(:inbox, account: account, channel: create(:channel_api, account: account)) }
  let(:sender) { create(:user, account: account, role: :administrator) }
  let(:known_contact) { create(:contact, account: account, phone_number: '+34600000001') }
  let(:cold_contact) { create(:contact, account: account, phone_number: '+34600000002') }
  let(:delivery_settings) { { 'batch_size' => 10 } }
  let(:contact_ids) { [known_contact.id, cold_contact.id] }
  let(:campaign) do
    create(:campaign, account: account, inbox: inbox, sender: sender, campaign_status: :running,
                      delivery_settings: delivery_settings,
                      delivery_state: { 'contact_ids' => contact_ids, 'total_contacts' => contact_ids.size,
                                        'processed_index' => 0, 'recipients' => {} })
  end
  let(:recipients) { campaign.reload.delivery_state['recipients'] }

  before do
    known_contact_inbox = create(:contact_inbox, contact: known_contact, inbox: inbox)
    known_conversation = create(:conversation, account: account, inbox: inbox, contact: known_contact,
                                               contact_inbox: known_contact_inbox)
    create(:message, account: account, inbox: inbox, conversation: known_conversation, message_type: :incoming)
    Redis::Alfred.scan_each(match: 'campaigns:new_contacts:*') { |key| Redis::Alfred.delete(key) }
  end

  context 'when new contacts are not allowed' do
    it 'only writes to contacts that already have a conversation with the inbox' do
      described_class.perform_now(campaign)

      expect(recipients[known_contact.id.to_s]['status']).to eq('sent')
      expect(recipients[cold_contact.id.to_s]['status']).to eq('skipped')
      expect(recipients[cold_contact.id.to_s]['error']).to eq(Campaigns::NewContactInboxService::NO_CONVERSATION_REASON)
    end

    it 'does not link contacts that never wrote to the inbox' do
      expect { described_class.perform_now(campaign) }.not_to(change { inbox.contact_inboxes.where(contact: cold_contact).count })
      expect(campaign.conversations.where(contact: cold_contact)).to be_empty
    end

    it 'skips contacts linked to the inbox that never wrote to it' do
      create(:contact_inbox, contact: cold_contact, inbox: inbox)

      described_class.perform_now(campaign)

      expect(recipients[cold_contact.id.to_s]['status']).to eq('skipped')
      expect(recipients[cold_contact.id.to_s]['error']).to eq(Campaigns::NewContactInboxService::NO_CONVERSATION_REASON)
    end
  end

  context 'when new contacts are allowed' do
    let(:delivery_settings) { { 'batch_size' => 10, 'allow_new_contacts' => true, 'max_new_contacts_per_day' => 1 } }
    let(:second_cold_contact) { create(:contact, account: account, phone_number: '+34600000003') }
    let(:no_phone_contact) { create(:contact, account: account, phone_number: nil, email: 'nophone@example.com') }
    let(:contact_ids) { [known_contact.id, no_phone_contact.id, cold_contact.id, second_cold_contact.id] }

    it 'writes to new contacts up to the daily limit of the inbox and waits until tomorrow for the rest' do
      expect { described_class.perform_now(campaign) }.to have_enqueued_job(described_class)

      expect(recipients.values_at(known_contact.id.to_s, cold_contact.id.to_s).pluck('status')).to eq(%w[sent sent])
      expect(recipients[no_phone_contact.id.to_s]['error']).to eq(Campaigns::NewContactInboxService::NO_PHONE_REASON)
      expect(recipients).not_to have_key(second_cold_contact.id.to_s)

      campaign.reload
      expect(campaign).to be_running
      expect(campaign.delivery_state['processed_index']).to eq(3)
      expect(campaign.delivery_state['errors'].last['system']).to eq('Daily new contacts limit reached')
    end

    it 'shares the daily limit between campaigns of the same inbox' do
      other_campaign = create(:campaign, account: account, inbox: inbox, sender: sender, campaign_status: :running,
                                         delivery_settings: delivery_settings,
                                         delivery_state: { 'contact_ids' => [second_cold_contact.id], 'total_contacts' => 1,
                                                           'processed_index' => 0, 'recipients' => {} })
      described_class.perform_now(campaign)
      described_class.perform_now(other_campaign)

      expect(other_campaign.reload.delivery_state['recipients']).to be_empty
      expect(other_campaign.delivery_state['processed_index']).to eq(0)
    end
  end
end
