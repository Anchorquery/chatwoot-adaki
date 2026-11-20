require 'rails_helper'

describe Campaigns::WhatsappAudienceService do
  subject(:service) { described_class.new(inbox) }

  let(:channel) do
    double(additional_attributes: { 'evolution_api_key' => 'secret-key' }, # rubocop:disable RSpec/VerifiedDoubles
           webhook_url: 'https://evo.example.com/chatwoot/webhook/miinstancia')
  end
  let(:inbox) { double(id: 1, channel: channel) } # rubocop:disable RSpec/VerifiedDoubles
  let(:json) { { 'Content-Type' => 'application/json' } }

  before do
    allow(ENV).to receive(:fetch).and_call_original
    allow(ENV).to receive(:fetch).with('EVOLUTION_ALLOW_PRIVATE_NETWORK', 'false').and_return('true')
  end

  describe '#chats' do
    let(:groups) do
      [
        { 'id' => '1@g.us', 'subject' => 'Vecinos', 'isCommunity' => true },
        { 'id' => '2@g.us', 'subject' => 'Vecinos Peñón', 'isCommunityAnnounce' => true, 'announce' => true, 'size' => 3 },
        { 'id' => '3@g.us', 'subject' => 'Junta', 'announce' => true, 'size' => 2 },
        { 'id' => '4@g.us', 'subject' => 'Abierto', 'announce' => false, 'size' => 5 }
      ]
    end
    let!(:groups_request) do
      stub_request(:get, %r{/group/fetchAllGroups/miinstancia})
        .with(query: { getParticipants: 'false' })
        .to_return(status: 200, body: groups.to_json, headers: json)
    end

    before do
      stub_request(:get, %r{/newsletter/find/miinstancia}).to_return(
        status: 200, body: [{ 'id' => '5@newsletter', 'name' => 'Canal' }].to_json, headers: json
      )
    end

    it 'lists groups without participants, hides community parents and marks the admin-only ones' do
      result = service.chats
      rows = result[:chats].index_by { |row| row[:id] }

      expect(groups_request).to have_been_requested
      expect(rows.keys).to eq(%w[4@g.us 5@newsletter 3@g.us 2@g.us])
      expect(rows['2@g.us']).to include(kind: 'community', size: 3, admins_only: true, can_send: nil)
      expect(rows['3@g.us']).to include(kind: 'group', admins_only: true, can_send: nil)
      expect(rows['4@g.us']).to include(admins_only: false, can_send: true)
      expect(rows['5@newsletter']).to include(kind: 'channel', can_send: nil)
      expect(result).to include(has_more: false, total: 4, groups_unavailable: false)
    end

    it 'searches by name ignoring case and accents, and filters by kind' do
      expect(service.chats(query: 'penon')[:chats].pluck(:id)).to eq(['2@g.us'])
      expect(service.chats(kind: 'channel')[:chats].pluck(:id)).to eq(['5@newsletter'])
    end

    it 'pages the list' do
      many = Array.new(31) { |index| { 'id' => "#{index}@g.us", 'subject' => format('Grupo %02d', index) } }
      stub_request(:get, %r{/group/fetchAllGroups/miinstancia}).to_return(status: 200, body: many.to_json, headers: json)

      first = service.chats(kind: 'group')
      second = service.chats(kind: 'group', page: 2)

      expect([first[:chats].size, first[:has_more]]).to eq([30, true])
      expect(second[:chats].pluck(:id)).to eq(['30@g.us'])
      expect(second[:has_more]).to be(false)
    end

    it 'still returns the channels and says so when the groups do not arrive' do
      stub_request(:get, %r{/group/fetchAllGroups/miinstancia}).to_timeout

      result = service.chats

      expect(result[:chats].pluck(:id)).to eq(['5@newsletter'])
      expect(result[:groups_unavailable]).to be(true)
    end
  end

  describe '#chat_permissions' do
    before do
      stub_request(:get, %r{/instance/fetchInstances}).to_return(
        status: 200, body: [{ 'ownerJid' => '34600000001@s.whatsapp.net' }].to_json, headers: json
      )
      stub_request(:get, %r{/group/participants/miinstancia}).with(query: { groupJid: '2@g.us' }).to_return(
        status: 200, headers: json, body: { participants: [{ 'id' => '34600000001@s.whatsapp.net', 'admin' => 'admin' }] }.to_json
      )
      stub_request(:get, %r{/group/participants/miinstancia}).with(query: { groupJid: '3@g.us' }).to_return(
        status: 200, headers: json,
        body: { participants: [{ 'id' => '9@lid', 'phoneNumber' => '34600000001@s.whatsapp.net', 'admin' => nil }] }.to_json
      )
      stub_request(:get, %r{/group/participants/miinstancia}).with(query: { groupJid: '6@g.us' }).to_return(status: 404)
    end

    it 'tells whether the inbox is admin of each chosen group' do
      expect(service.chat_permissions(%w[2@g.us 3@g.us 6@g.us 5@newsletter])).to eq(
        '2@g.us' => true, '3@g.us' => false, '6@g.us' => nil
      )
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
