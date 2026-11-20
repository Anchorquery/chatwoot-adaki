require 'rails_helper'

RSpec.describe Campaigns::AudiencePreviewService do
  let(:account) { create(:account) }
  let(:inbox) { create(:inbox, account: account, channel: create(:channel_api, account: account)) }
  let(:vip) { create(:label, account: account, title: 'vip') }
  let(:baja) { create(:label, account: account, title: 'baja') }
  let!(:known) { create(:contact, account: account, phone_number: '+34600000001') }
  let!(:cold) { create(:contact, account: account, phone_number: '+34600000002') }
  let!(:unsubscribed) { create(:contact, account: account, phone_number: '+34600000003') }

  before do
    [known, cold, unsubscribed].each { |contact| contact.update!(label_list: [vip.title]) }
    unsubscribed.update!(label_list: [vip.title, baja.title])
    conversation = create(:conversation, account: account, inbox: inbox, contact: known)
    create(:message, account: account, inbox: inbox, conversation: conversation, message_type: :incoming)
  end

  def preview(allow_new_contacts: false)
    described_class.new(
      account: account, inbox: inbox,
      audience: [{ 'type' => 'Label', 'id' => vip.id }, { 'type' => 'ExcludeLabel', 'id' => baja.id },
                 { 'type' => 'WhatsappChat', 'id' => '1@g.us' }, { 'type' => 'Phone', 'id' => '600000002' },
                 { 'type' => 'Phone', 'id' => '600999999' }, { 'type' => 'Phone', 'id' => '12' }],
      delivery_settings: { 'allow_new_contacts' => allow_new_contacts, 'max_new_contacts_per_day' => 5 }
    ).perform
  end

  it 'counts recipients, exclusions and cold contacts without creating anything' do
    expect { preview }.not_to change(Contact, :count)

    expect(preview).to include(label_contacts: 3, excluded: 1, chats: 1, phones: 2, invalid_phones: 1,
                               new_phone_contacts: 1, cold_contacts: 2, total: 4, reachable: 2,
                               daily_new_contacts_limit: 5, allow_new_contacts: false)
  end

  it 'reaches cold contacts when new contacts are allowed' do
    expect(preview(allow_new_contacts: true)).to include(reachable: 4)
  end
end
