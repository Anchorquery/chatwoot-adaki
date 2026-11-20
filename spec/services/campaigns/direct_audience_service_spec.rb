require 'rails_helper'

RSpec.describe Campaigns::DirectAudienceService do
  let(:account) { create(:account) }
  let(:inbox) { create(:inbox, account: account, channel: create(:channel_api, account: account)) }
  let(:campaign) { create(:campaign, account: account, inbox: inbox, audience: audience) }

  def contact_ids
    described_class.new(campaign: campaign).contact_ids
  end

  context 'with a WhatsApp group that is not in Chatwoot yet' do
    let(:audience) { [{ 'type' => 'WhatsappChat', 'id' => '120363000000000001@g.us', 'name' => 'Vecinos (avisos)' }] }

    it 'creates the contact with the JID and links it to the inbox' do
      ids = contact_ids

      contact = account.contacts.find_by(identifier: '120363000000000001@g.us')
      expect(ids).to eq([contact.id])
      expect(contact.name).to eq('Vecinos (avisos) (GROUP)')
      expect(inbox.contact_inboxes.where(contact: contact)).to exist
    end

    it 'reuses the contact Evolution already created' do
      existing = create(:contact, account: account, identifier: '120363000000000001@g.us', name: 'Vecinos (GROUP)')
      create(:contact_inbox, contact: existing, inbox: inbox)

      expect { contact_ids }.not_to change(ContactInbox, :count)
      expect(contact_ids).to eq([existing.id])
    end
  end

  context 'with a value that is not a WhatsApp chat' do
    let(:audience) { [{ 'type' => 'WhatsappChat', 'id' => '34600111222@s.whatsapp.net' }] }

    it 'ignores it' do
      expect(contact_ids).to be_empty
    end
  end

  context 'with loose phone numbers' do
    let(:audience) do
      [{ 'type' => 'Phone', 'id' => '600 111 222' }, { 'type' => 'Phone', 'id' => '0034 600111333' },
       { 'type' => 'Phone', 'id' => 'abc' }, { 'type' => 'Label', 'id' => 1 }]
    end

    it 'finds or creates contacts without linking them to the inbox' do
      known = create(:contact, account: account, phone_number: '+34600111222')

      ids = contact_ids

      created = account.contacts.find_by(phone_number: '+34600111333')
      expect(ids).to eq([known.id, created.id])
      expect(inbox.contact_inboxes.where(contact_id: ids)).to be_empty
    end
  end
end
