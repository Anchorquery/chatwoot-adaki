require 'rails_helper'

RSpec.describe CaptainInbox do
  let(:account) { create(:account) }
  let(:inbox) { create(:inbox, account: account) }
  let(:assistant) { create(:captain_assistant, account: account) }

  describe '#service_contact_numbers_value' do
    it 'falls back to Conversation::DEFAULT_SERVICE_CONTACT_NUMBERS when unset' do
      captain_inbox = create(:captain_inbox, inbox: inbox, captain_assistant: assistant)

      expect(captain_inbox.service_contact_numbers_value).to eq(Conversation::DEFAULT_SERVICE_CONTACT_NUMBERS)
    end

    it 'falls back to the default when the setting is an empty array' do
      captain_inbox = create(:captain_inbox, inbox: inbox, captain_assistant: assistant,
                                             settings: { 'service_contact_numbers' => [] })

      expect(captain_inbox.service_contact_numbers_value).to eq(Conversation::DEFAULT_SERVICE_CONTACT_NUMBERS)
    end

    it 'honors an explicit override' do
      captain_inbox = create(:captain_inbox, inbox: inbox, captain_assistant: assistant,
                                             settings: { 'service_contact_numbers' => ['+15550000000'] })

      expect(captain_inbox.service_contact_numbers_value).to eq(['+15550000000'])
    end
  end
end
