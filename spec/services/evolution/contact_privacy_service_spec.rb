require 'rails_helper'

describe Evolution::ContactPrivacyService do
  subject(:service) { described_class.new(inbox, contact) }

  let(:channel) { double(additional_attributes: { 'evolution_api_key' => 'token' }, webhook_url: 'https://evo.example.com/chatwoot/webhook/ventas') } # rubocop:disable RSpec/VerifiedDoubles
  let(:inbox) { double(channel: channel) } # rubocop:disable RSpec/VerifiedDoubles
  let(:contact) { instance_double(Contact, identifier: '34600111222@s.whatsapp.net', phone_number: '+34600111222') }
  let(:find_url) { 'https://evo.example.com/chatwoot/find/ventas' }
  let(:set_url) { 'https://evo.example.com/chatwoot/set/ventas' }

  before do
    allow(ENV).to receive(:fetch).and_call_original
    allow(ENV).to receive(:fetch).with('EVOLUTION_ALLOW_PRIVATE_NETWORK', 'false').and_return('true')
  end

  def stub_config(config)
    stub_request(:get, find_url).to_return(
      status: 200, body: { 'enabled' => true, 'id' => 'x' }.merge(config).to_json, headers: { 'Content-Type' => 'application/json' }
    )
  end

  def saved_body
    body = nil
    stub_request(:post, set_url).with { |req| body = JSON.parse(req.body) }.to_return(status: 201, body: '{}')
    -> { body }
  end

  describe '#status' do
    it 'reports a blocked contact, also when the Manager saved the bare number' do
      stub_config('ignoreJids' => ['34600111222'], 'allowedJids' => [])

      expect(service.status).to eq(status: 'ok', filtered: true, mode: 'block')
    end

    it 'reports a contact missing from the allow list as filtered' do
      stub_config('ignoreJids' => [], 'allowedJids' => ['34999@s.whatsapp.net'])

      expect(service.status).to eq(status: 'ok', filtered: true, mode: 'allow')
    end
  end

  describe '#update' do
    it 'adds the contact to the blocked list without touching the rest' do
      stub_config('ignoreJids' => ['1@g.us'], 'allowedJids' => [])
      body = saved_body

      expect(service.update(filtered: true)).to eq(success: true, message: 'ok')
      expect(body.call).to include('ignoreJids' => ['1@g.us', '34600111222@s.whatsapp.net'], 'allowedJids' => [])
      expect(body.call).not_to have_key('id')
    end

    it 'removes every variant of the contact when receiving it again' do
      stub_config('ignoreJids' => ['34600111222', '34600111222@s.whatsapp.net', '1@g.us'], 'allowedJids' => [])
      body = saved_body

      service.update(filtered: false)

      expect(body.call['ignoreJids']).to eq(['1@g.us'])
    end

    it 'takes the contact out of the allow list in allow mode' do
      stub_config('ignoreJids' => [], 'allowedJids' => ['34600111222@s.whatsapp.net', '34999@s.whatsapp.net'])
      body = saved_body

      service.update(filtered: true)

      expect(body.call['allowedJids']).to eq(['34999@s.whatsapp.net'])
    end

    # Una lista de permitidos vacía es "recibir todo": lo contrario de lo pedido.
    it 'refuses to remove the last allowed chat' do
      stub_config('ignoreJids' => [], 'allowedJids' => ['34600111222@s.whatsapp.net'])
      set_stub = stub_request(:post, set_url)

      expect(service.update(filtered: true)).to eq(success: false, message: 'last_allowed')
      expect(set_stub).not_to have_been_requested
    end

    it 'does not write when the current filter cannot be read' do
      stub_request(:get, find_url).to_return(status: 502, body: '')
      set_stub = stub_request(:post, set_url)

      expect(service.update(filtered: true)).to eq(success: false, message: 'unreachable')
      expect(set_stub).not_to have_been_requested
    end
  end
end
