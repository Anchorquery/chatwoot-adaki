require 'rails_helper'

RSpec.describe CaptainInboxAudience do
  let(:account) { create(:account) }
  let(:inbox) { create(:inbox, account: account) }
  let(:assistant) { create(:captain_assistant, account: account) }

  describe 'validations' do
    it 'is invalid without group_jids or label_titles' do
      audience = described_class.new(inbox: inbox, captain_assistant: assistant)

      expect(audience).not_to be_valid
      expect(audience.errors[:base]).to include('must define at least one group_jid or label_title')
    end

    it 'is valid with only group_jids' do
      audience = described_class.new(inbox: inbox, captain_assistant: assistant, group_jids: ['1203630000000'])

      expect(audience).to be_valid
    end

    it 'is valid with only label_titles' do
      audience = described_class.new(inbox: inbox, captain_assistant: assistant, label_titles: ['vip'])

      expect(audience).to be_valid
    end
  end

  describe 'normalization' do
    it 'strips the @g.us suffix and dedupes group_jids' do
      audience = create(:captain_inbox_audience, inbox: inbox, captain_assistant: assistant,
                                                 group_jids: ['1203630000000@g.us', '1203630000000'])

      expect(audience.group_jids).to eq(['1203630000000'])
    end

    it 'downcases and strips label_titles' do
      audience = create(:captain_inbox_audience, inbox: inbox, captain_assistant: assistant,
                                                 group_jids: [], label_titles: [' VIP '])

      expect(audience.label_titles).to eq(['vip'])
    end
  end

  describe '#matches?' do
    let(:contact) { create(:contact, account: account) }
    let(:contact_inbox) { create(:contact_inbox, inbox: inbox, contact: contact, source_id: '1203630000000@g.us') }
    let(:conversation) { create(:conversation, account: account, inbox: inbox, contact: contact, contact_inbox: contact_inbox) }

    it 'matches by group_jid' do
      audience = create(:captain_inbox_audience, inbox: inbox, captain_assistant: assistant,
                                                 group_jids: ['1203630000000'], label_titles: [])

      expect(audience.matches?(conversation)).to be true
    end

    it 'does not match a different group_jid' do
      audience = create(:captain_inbox_audience, inbox: inbox, captain_assistant: assistant,
                                                 group_jids: ['999999999999'], label_titles: [])

      expect(audience.matches?(conversation)).to be false
    end

    it 'matches by label' do
      conversation.update!(label_list: ['vip'])
      audience = create(:captain_inbox_audience, inbox: inbox, captain_assistant: assistant,
                                                 group_jids: [], label_titles: ['vip'])

      expect(audience.matches?(conversation)).to be true
    end

    it 'does not match when neither group_jid nor labels match' do
      audience = create(:captain_inbox_audience, inbox: inbox, captain_assistant: assistant,
                                                 group_jids: ['999999999999'], label_titles: ['other'])

      expect(audience.matches?(conversation)).to be false
    end
  end
end
