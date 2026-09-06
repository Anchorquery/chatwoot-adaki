require 'rails_helper'

RSpec.describe Captain::Tools::RegistryService do
  let(:account) { create(:account) }
  let(:assistant) { create(:captain_assistant, account: account) }
  let(:registry) { described_class.new(account: account, assistant: assistant) }

  describe '#assistant_tools' do
    it 'gives the orchestrator lookup, handoff and the housekeeping tools' do
      expect(registry.assistant_tools.map(&:name)).to contain_exactly(
        'faq_lookup', 'handoff',
        'add_label_to_conversation', 'update_priority', 'add_private_note', 'add_contact_note',
        'resolve_conversation'
      )
    end

    # search_documentation queries the same index as faq_lookup; offering both
    # made the model verify one with the other, an extra embedding plus a full
    # LLM round-trip per answer.
    it 'does not offer search_documentation alongside faq_lookup' do
      expect(registry.assistant_tools.map(&:name)).not_to include('search_documentation')
    end
  end

  describe '#available_tool_metadata' do
    it 'still lists every built-in tool for scenario configuration, search_documentation and resolve included' do
      ids = registry.available_tool_ids

      expect(ids).to include('faq_lookup', 'search_documentation', 'handoff',
                             'add_label_to_conversation', 'resolve_conversation')
      expect(registry.tool_instance('search_documentation')).to be_a(Captain::Tools::SearchDocumentationTool)
    end

    it 'queries custom tools and MCP servers once per registry, however many lookups follow' do
      allow(account).to receive(:captain_custom_tools).and_call_original
      allow(account).to receive(:captain_mcp_servers).and_call_original

      3.times { registry.tool_instance('faq_lookup') }
      registry.available_tool_ids

      expect(account).to have_received(:captain_custom_tools).once
      expect(account).to have_received(:captain_mcp_servers).once
    end
  end

  describe 'sharing through Captain::Assistant#cache_tool_registry' do
    before do
      create(:captain_scenario, assistant: assistant, account: account)
      create(:captain_scenario, assistant: assistant, account: account)
      assistant.reload
      allow(described_class).to receive(:new).and_call_original
    end

    it 'builds one registry for the assistant and all its scenarios while the agent graph is built' do
      assistant.cache_tool_registry do
        assistant.available_agent_tools
        assistant.scenarios.enabled.each { |scenario| scenario.send(:agent_tools) }
      end

      expect(described_class).to have_received(:new).once
    end

    it 'goes back to a fresh registry per lookup outside the block, so a tool disabled later is not served stale' do
      custom_tool = create(:captain_custom_tool, account: account, slug: 'custom_fetch-order')
      assistant.cache_tool_registry { assistant.available_agent_tools }
      custom_tool.update!(enabled: false)

      expect(assistant.available_agent_tools.pluck(:id)).not_to include('custom_fetch-order')
    end
  end
end
