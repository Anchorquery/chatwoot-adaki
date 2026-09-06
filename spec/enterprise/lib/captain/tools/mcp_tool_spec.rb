require 'rails_helper'

RSpec.describe Captain::Tools::McpTool do
  let(:account) { create(:account) }
  let(:assistant) { create(:captain_assistant, account: account) }
  let(:server) do
    instance_double(Captain::McpServer, id: 1, slug: 'crm', enabled?: true, transport_type: 'streamable_http',
                                        platform_credential: nil)
  end
  let(:client) { instance_double(Platform::Mcp::Client) }
  let(:tool) { described_class.new(assistant, server, { id: 'mcp_crm_lookup', tool_name: 'lookup' }) }

  before do
    allow(Platform::Mcp::Client).to receive(:new).with(server: server).and_return(client)
    allow(client).to receive(:call_tool).and_return({ 'content' => [{ 'text' => 'ok' }] })
  end

  it 'reuses one MCP client (and therefore one initialized session) across calls within a turn' do
    tool.perform(nil, id: 1)
    tool.perform(nil, id: 2)

    expect(Platform::Mcp::Client).to have_received(:new).once
    expect(client).to have_received(:call_tool).with(tool_name: 'lookup', arguments: { id: 1 })
    expect(client).to have_received(:call_tool).with(tool_name: 'lookup', arguments: { id: 2 })
  end

  it 'returns the normalized text of the tool result' do
    expect(tool.perform(nil, id: 1)).to eq('ok')
  end
end
