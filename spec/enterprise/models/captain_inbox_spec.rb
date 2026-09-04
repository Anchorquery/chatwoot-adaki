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

  describe '#handoff_team' do
    let(:team) { create(:team, account: account) }
    let(:other_team) { create(:team, account: account) }

    it 'is nil when neither the inbox nor the assistant configured one' do
      captain_inbox = create(:captain_inbox, inbox: inbox, captain_assistant: assistant)

      expect(captain_inbox.handoff_team_id_value).to be_nil
      expect(captain_inbox.handoff_team).to be_nil
    end

    it 'inherits the assistant team' do
      assistant.update!(config: assistant.config.merge('handoff_team_id' => team.id))
      captain_inbox = create(:captain_inbox, inbox: inbox, captain_assistant: assistant)

      expect(captain_inbox.handoff_team).to eq(team)
    end

    it 'lets the inbox override the assistant team' do
      assistant.update!(config: assistant.config.merge('handoff_team_id' => team.id))
      captain_inbox = create(:captain_inbox, inbox: inbox, captain_assistant: assistant,
                                             settings: { 'handoff_team_id' => other_team.id })

      expect(captain_inbox.handoff_team).to eq(other_team)
    end

    it 'treats an explicit 0 override as "no team" even when the assistant has one' do
      assistant.update!(config: assistant.config.merge('handoff_team_id' => team.id))
      captain_inbox = create(:captain_inbox, inbox: inbox, captain_assistant: assistant,
                                             settings: { 'handoff_team_id' => 0 })

      expect(captain_inbox.handoff_team_id_value).to be_nil
      expect(captain_inbox.handoff_team).to be_nil
    end

    it 'ignores a team that no longer exists or belongs to another account' do
      foreign_team = create(:team)
      captain_inbox = create(:captain_inbox, inbox: inbox, captain_assistant: assistant,
                                             settings: { 'handoff_team_id' => foreign_team.id })

      expect(captain_inbox.handoff_team).to be_nil
    end
  end
end
