require 'rails_helper'

RSpec.describe Captain::Tools::McpTool do
  let(:account) { create(:account) }
  let(:assistant) { create(:captain_assistant, account: account) }
  let(:server) do
    instance_double(Captain::McpServer, id: 1, slug: 'crm', name: 'CRM', enabled?: true,
                                        transport_type: 'streamable_http', platform_credential: nil)
  end
  let(:client) { instance_double(Platform::Mcp::Client) }
  let(:input_schema) do
    {
      'type' => 'object',
      'properties' => {
        'order_id' => { 'type' => 'string', 'description' => 'The order reference' },
        'channel' => { 'type' => 'string', 'enum' => %w[web whatsapp] }
      },
      'required' => ['order_id']
    }
  end
  let(:metadata) do
    { id: 'mcp_crm_lookup', tool_name: 'lookup', server_name: 'CRM',
      description: 'Look up an order by reference', input_schema: input_schema }
  end
  let(:tool) { described_class.build(assistant, server, metadata) }

  before do
    allow(Platform::Mcp::Client).to receive(:new).with(server: server).and_return(client)
    allow(client).to receive(:call_tool).and_return({ 'content' => [{ 'text' => 'ok' }] })
  end

  # What the model actually receives. Before .build existed these were nil and
  # {} for every MCP tool, so the model saw a bare name and could not pass a
  # single argument.
  describe 'the definition handed to the model' do
    it 'carries the tool name, its description and its argument schema' do
      expect(tool.name).to eq('mcp_crm_lookup')
      expect(tool.description).to eq('Look up an order by reference')
      expect(tool.params_schema).to include('type' => 'object')
      expect(tool.params_schema['properties'].keys).to contain_exactly('order_id', 'channel')
      expect(tool.params_schema['required']).to eq(['order_id'])
    end

    # Handing the JSON Schema over verbatim (rather than flattening it into
    # `param` declarations) is what keeps enums and per-property descriptions.
    it 'preserves enums and descriptions from the server schema' do
      expect(tool.params_schema.dig('properties', 'channel', 'enum')).to eq(%w[web whatsapp])
      expect(tool.params_schema.dig('properties', 'order_id', 'description')).to eq('The order reference')
    end

    it 'gives each tool of the same server its own definition' do
      other = described_class.build(assistant, server,
                                    metadata.merge(id: 'mcp_crm_refund', tool_name: 'refund',
                                                   description: 'Refund an order', input_schema: nil))

      expect(other.description).to eq('Refund an order')
      expect(tool.description).to eq('Look up an order by reference')
      expect(other.name).to eq('mcp_crm_refund')
    end

    it 'synthesizes a description when the server advertises none, rather than sending nil' do
      undocumented = described_class.build(assistant, server, metadata.merge(description: nil))

      expect(undocumented.description).to eq('Tool "lookup" provided by the CRM MCP server.')
    end
  end

  # RubyLLM's Gemini adapter raises ArgumentError unless the tool schema is an
  # object, and available_tool_metadata defaults input_schema to {}.
  describe 'schemas the providers would reject' do
    it 'drops a schema that is not an object instead of breaking the agent build' do
      [{}, nil, 'not a schema', { 'type' => 'string' }].each do |bad|
        built = described_class.build(assistant, server, metadata.merge(input_schema: bad))

        expect(built.params_schema['type']).to eq('object')
        expect(built.params_schema['properties']).to be_blank
      end
    end

    it 'keeps an object schema that declares no properties (a no-argument tool)' do
      built = described_class.build(assistant, server, metadata.merge(input_schema: { 'type' => 'object', 'properties' => {} }))

      expect(built.params_schema['type']).to eq('object')
    end
  end

  describe '#perform' do
    it 'forwards the arguments to the MCP server and returns the normalized text' do
      expect(tool.perform(nil, order_id: 'A-1')).to eq('ok')
      expect(client).to have_received(:call_tool).with(tool_name: 'lookup', arguments: { order_id: 'A-1' })
    end

    it 'reuses one MCP client (and therefore one session) across calls within a turn' do
      tool.perform(nil, order_id: 'A-1')
      tool.perform(nil, order_id: 'A-2')

      expect(Platform::Mcp::Client).to have_received(:new).once
    end

    # An opaque "an error occurred" left the model with no basis to decide
    # whether to retry, ask the customer or hand off.
    it 'tells the model what failed and what to do next' do
      allow(client).to receive(:call_tool).and_raise(StandardError, 'upstream 503')

      result = tool.perform(nil, order_id: 'A-1')

      expect(result).to include('lookup', 'upstream 503')
      expect(result).to include('hand off')
    end
  end
end
