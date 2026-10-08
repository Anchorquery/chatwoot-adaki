require 'rails_helper'

describe Evolution::InboxClient do
  # ConnectionService es un InboxClient concreto con una llamada sencilla.
  subject(:service) { Evolution::ConnectionService.new(inbox) }

  let(:additional_attributes) { {} }
  let(:webhook_url) { 'https://evo.example.com/chatwoot/webhook/ventas' }
  let(:channel) { double(additional_attributes: additional_attributes, webhook_url: webhook_url) } # rubocop:disable RSpec/VerifiedDoubles
  let(:inbox) { double(channel: channel) } # rubocop:disable RSpec/VerifiedDoubles
  let(:configured_url) { 'https://evo.example.com' }
  let(:state_url) { 'https://evo.example.com/instance/connectionState/ventas' }

  before do
    allow(GlobalConfigService).to receive(:load).and_call_original
    allow(GlobalConfigService).to receive(:load).with('EVOLUTION_API_URL', '').and_return(configured_url)
    allow(GlobalConfigService).to receive(:load).with('EVOLUTION_API_KEY', '').and_return('GLOBAL-KEY')
    allow(ENV).to receive(:fetch).and_call_original
    allow(ENV).to receive(:fetch).with('EVOLUTION_ALLOW_PRIVATE_NETWORK', 'false').and_return('true')
  end

  def stub_state(key)
    stub_request(:get, state_url).with(headers: { 'apikey' => key })
                                 .to_return(status: 200, body: { instance: { state: 'close' } }.to_json)
  end

  # Bandejas vinculadas desde el Manager de Evolution, sin apikey guardada.
  it 'uses the global key for an inbox of the configured Evolution server' do
    stub = stub_state('GLOBAL-KEY')

    expect(service).to be_linked
    expect(service.connection_state).to eq(status: 'ok', state: 'close')
    expect(stub).to have_been_requested
  end

  it 'treats a trailing slash or upper case host as the same server' do
    allow(GlobalConfigService).to receive(:load).with('EVOLUTION_API_URL', '').and_return('https://EVO.example.com/')

    expect(service).to be_linked
  end

  it 'prefers the key stored in the inbox' do
    additional_attributes['evolution_api_key'] = 'INSTANCE-TOKEN'
    stub = stub_state('INSTANCE-TOKEN')

    service.connection_state

    expect(stub).to have_been_requested
  end

  # El webhook_url lo edita un admin: apuntarlo a otro host no puede servir
  # para llevarse la clave global.
  context 'when the webhook points to another server' do
    let(:webhook_url) { 'https://attacker.example.net/chatwoot/webhook/ventas' }

    it 'never sends the global key there' do
      expect(service).not_to be_linked
      expect(service.connection_state).to eq(status: 'not_configured')
      expect(a_request(:any, /attacker\.example\.net/)).not_to have_been_made
    end
  end

  context 'when Evolution is not configured in Super Admin' do
    let(:configured_url) { '' }

    it 'needs a key stored in the inbox' do
      expect(service).not_to be_linked
    end
  end
end
