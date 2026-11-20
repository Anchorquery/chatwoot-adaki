require 'rails_helper'

describe Campaigns::WhatsappAudienceService do
  subject(:service) { described_class.new(inbox) }

  let(:channel) do
    double(additional_attributes: { 'evolution_api_key' => 'secret-key' }, # rubocop:disable RSpec/VerifiedDoubles
           webhook_url: 'https://evo.example.com/chatwoot/webhook/miinstancia')
  end
  let(:inbox) { double(channel: channel) } # rubocop:disable RSpec/VerifiedDoubles
  let(:json) { { 'Content-Type' => 'application/json' } }

  before do
    allow(ENV).to receive(:fetch).and_call_original
    allow(ENV).to receive(:fetch).with('EVOLUTION_ALLOW_PRIVATE_NETWORK', 'false').and_return('true')
  end

  describe '#chats' do
    let(:groups) do
      [
        { 'id' => '1@g.us', 'subject' => 'Vecinos', 'isCommunity' => true, 'participants' => [] },
        { 'id' => '2@g.us', 'subject' => 'Vecinos', 'isCommunityAnnounce' => true, 'announce' => true, 'size' => 3,
          'participants' => [{ 'id' => '34600000001@s.whatsapp.net', 'admin' => 'admin' }] },
        { 'id' => '3@g.us', 'subject' => 'Junta', 'announce' => true, 'size' => 2,
          'participants' => [{ 'id' => '9@lid', 'phoneNumber' => '34600000001@s.whatsapp.net', 'admin' => nil }] },
        { 'id' => '4@g.us', 'subject' => 'Abierto', 'announce' => false, 'size' => 5, 'participants' => [] }
      ]
    end

    before do
      stub_request(:get, %r{/instance/fetchInstances}).to_return(
        status: 200, body: [{ 'ownerJid' => '34600000001@s.whatsapp.net' }].to_json, headers: json
      )
      stub_request(:get, %r{/group/fetchAllGroups/miinstancia}).to_return(status: 200, body: groups.to_json, headers: json)
      stub_request(:get, %r{/newsletter/find/miinstancia}).to_return(
        status: 200, body: [{ 'id' => '5@newsletter', 'name' => 'Canal' }].to_json, headers: json
      )
    end

    it 'hides community parents and tells where the inbox can post' do
      rows = service.chats.index_by { |row| row[:id] }

      expect(rows.keys).to contain_exactly('2@g.us', '3@g.us', '4@g.us', '5@newsletter')
      expect(rows['2@g.us']).to include(kind: 'community', size: 3, can_send: true)
      expect(rows['3@g.us']).to include(kind: 'group', can_send: false)
      expect(rows['4@g.us']).to include(can_send: true)
      expect(rows['5@newsletter']).to include(kind: 'channel', can_send: nil)
      expect(rows.values.flat_map(&:keys)).not_to include(:participants)
    end
  end

  describe '#check_numbers' do
    it 'returns which numbers have WhatsApp' do
      stub_request(:post, 'https://evo.example.com/chat/whatsappNumbers/miinstancia')
        .with(body: { numbers: %w[34600000001 34600000002] }.to_json)
        .to_return(status: 200, headers: json, body: [
          { 'number' => '34600000001', 'exists' => true, 'jid' => '34600000001@s.whatsapp.net' },
          { 'number' => '34600000002', 'exists' => false }
        ].to_json)

      result = service.check_numbers(%w[34600000001 34600000002 34600000001])

      expect(result).to eq(status: 'ok', results: [{ number: '34600000001', exists: true },
                                                   { number: '34600000002', exists: false }])
    end

    it 'reports when Evolution does not answer' do
      stub_request(:post, %r{/chat/whatsappNumbers/}).to_return(status: 500)

      expect(service.check_numbers(['34600000001'])).to eq(status: 'unreachable')
    end
  end
end
