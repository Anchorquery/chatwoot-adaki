require 'rails_helper'

RSpec.describe Captain::Tools::RegistryService do
  let(:account) { create(:account) }
  let(:assistant) { create(:captain_assistant, account: account) }

  describe '#assistant_tools' do
    it 'gives the orchestrator the lookup, handoff and housekeeping tools (resolve stays scenario-only)' do
      names = described_class.new(account: account, assistant: assistant).assistant_tools.map(&:name)

      expect(names).to contain_exactly(
        'faq_lookup', 'search_documentation', 'handoff',
        'add_label_to_conversation', 'update_priority', 'add_private_note', 'add_contact_note'
      )
      expect(names).not_to include('resolve_conversation')
    end
  end

  describe '#available_tool_metadata' do
    it 'still lists every built-in tool for scenario configuration, resolve included' do
      ids = described_class.new(account: account, assistant: assistant).available_tool_ids

      expect(ids).to include('resolve_conversation', 'add_label_to_conversation', 'handoff')
    end
  end
end
