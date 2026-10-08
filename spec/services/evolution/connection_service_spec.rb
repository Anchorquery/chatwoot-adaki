require 'rails_helper'

describe Evolution::ConnectionService do
  subject(:service) { described_class.new(inbox) }

  let(:webhook_url) { 'https://evo.example.com/chatwoot/webhook/mi%20instancia' }
  let(:additional_attributes) { { 'evolution_api_key' => 'instance-token' } }
  let(:channel) { double(additional_attributes: additional_attributes, webhook_url: webhook_url) } # rubocop:disable RSpec/VerifiedDoubles
  let(:inbox) { double(channel: channel) } # rubocop:disable RSpec/VerifiedDoubles

  let(:state_url) { 'https://evo.example.com/instance/connectionState/mi%20instancia' }
  let(:connect_url) { 'https://evo.example.com/instance/connect/mi%20instancia' }
  let(:fetch_url) { 'https://evo.example.com/instance/fetchInstances' }

  before do
    allow(ENV).to receive(:fetch).and_call_original
    allow(ENV).to receive(:fetch).with('EVOLUTION_ALLOW_PRIVATE_NETWORK', 'false').and_return('true')
  end

  def json_response(body, status: 200)
    { status: status, body: body.to_json, headers: { 'Content-Type' => 'application/json' } }
  end

  describe '#connection_state' do
    it 'includes the linked number and profile when the session is open' do
      stub_request(:get, state_url).to_return(json_response({ instance: { state: 'open' } }))
      stub_request(:get, fetch_url).with(query: { 'instanceName' => 'mi instancia' }).to_return(
        json_response([{ ownerJid: '34600111222@s.whatsapp.net', profileName: 'Soporte', profilePicUrl: nil }])
      )

      expect(service.connection_state).to eq(
        { status: 'ok', state: 'open', phone_number: '34600111222', profile_name: 'Soporte' }
      )
    end

    it 'still reports open when the profile lookup fails' do
      stub_request(:get, state_url).to_return(json_response({ instance: { state: 'open' } }))
      stub_request(:get, fetch_url).with(query: { 'instanceName' => 'mi instancia' }).to_return(status: 500, body: '')

      expect(service.connection_state).to eq({ status: 'ok', state: 'open' })
    end

    it 'reports a waiting session without asking for the profile' do
      stub_request(:get, state_url).to_return(json_response({ instance: { state: 'connecting' } }))

      expect(service.connection_state).to eq({ status: 'ok', state: 'connecting' })
      expect(a_request(:get, /fetchInstances/)).not_to have_been_made
    end

    it 'reports the HTTP status when Evolution rejects the key' do
      stub_request(:get, state_url).to_return(status: 401, body: '')

      expect(service.connection_state).to eq({ status: 'http_401' })
    end

    context 'when the inbox has no evolution api key' do
      let(:additional_attributes) { {} }

      it 'reports not_configured' do
        expect(service.connection_state).to eq({ status: 'not_configured' })
      end
    end
  end

  describe '#connect' do
    it 'returns the QR code while waiting for the scan' do
      stub_request(:get, connect_url).to_return(
        json_response({ base64: 'data:image/png;base64,AAA', code: '2@xyz', pairingCode: nil, count: 1 })
      )

      expect(service.connect).to eq(
        { status: 'ok', state: 'connecting', qr_code: 'data:image/png;base64,AAA', pairing_code: nil }
      )
    end

    # El QR acaba en un <img src>: nada que no sea una imagen en data URI.
    it 'drops a QR that is not an inline image' do
      stub_request(:get, connect_url).to_return(json_response({ base64: 'https://evil.example.com/x.png' }))

      expect(service.connect).to include(qr_code: nil)
    end

    it 'reports open when the session is already connected' do
      stub_request(:get, connect_url).to_return(json_response({ instance: { instanceName: 'mi instancia', state: 'open' } }))
      stub_request(:get, fetch_url).with(query: { 'instanceName' => 'mi instancia' }).to_return(json_response([]))

      expect(service.connect).to eq({ status: 'ok', state: 'open' })
    end

    # connectToWhatsapp rescata sus propios errores y responde 200.
    it 'reports an Evolution error returned with HTTP 200' do
      stub_request(:get, connect_url).to_return(json_response({ error: true, message: 'boom' }))

      expect(service.connect).to eq({ status: 'evolution_error' })
    end
  end

  describe '#logout' do
    it 'closes the session in Evolution' do
      stub = stub_request(:delete, 'https://evo.example.com/instance/logout/mi%20instancia').to_return(json_response({}))

      expect(service.logout).to eq({ success: true, message: 'ok' })
      expect(stub).to have_been_requested
    end
  end

  describe '#restart' do
    let(:restart_url) { 'https://evo.example.com/instance/restart/mi%20instancia' }

    it 'restarts the connection' do
      stub_request(:post, restart_url).to_return(json_response({ instance: { status: 'connecting' } }))

      expect(service.restart).to eq({ success: true, message: 'ok' })
    end

    # restartInstance rescata sus propios errores y responde 200.
    it 'reports an Evolution error returned with HTTP 200' do
      stub_request(:post, restart_url).to_return(json_response({ error: true, message: 'not connected' }))

      expect(service.restart).to eq({ success: false, message: 'evolution_error' })
    end
  end

  describe 'instance settings' do
    let(:find_url) { 'https://evo.example.com/settings/find/mi%20instancia' }
    let(:set_url) { 'https://evo.example.com/settings/set/mi%20instancia' }
    let(:evolution_settings) do
      {
        rejectCall: true, msgCall: 'Solo chat', groupsIgnore: false, alwaysOnline: false, readMessages: true,
        readStatus: false, syncFullHistory: true, newsletterIgnore: false, wavoipToken: 'wav-token'
      }
    end

    it 'returns the settings with Chatwoot names, hiding internal fields' do
      stub_request(:get, find_url).to_return(json_response(evolution_settings))

      expect(service.instance_settings).to eq(
        status: 'ok',
        settings: {
          'reject_call' => true, 'msg_call' => 'Solo chat', 'groups_ignore' => false, 'newsletter_ignore' => false,
          'always_online' => false, 'read_messages' => true, 'read_status' => false
        }
      )
    end

    # Evolution responde 200 con null cuando no puede leerlos: no es "todo apagado".
    it 'reports a null body as an error' do
      stub_request(:get, find_url).to_return(status: 200, body: 'null', headers: { 'Content-Type' => 'application/json' })

      expect(service.instance_settings).to eq({ status: 'invalid_response' })
    end

    it 'keeps the fields the UI does not manage when saving' do
      stub_request(:get, find_url).to_return(json_response(evolution_settings))
      set_stub = stub_request(:post, set_url).to_return(json_response({}, status: 201))

      result = service.update_instance_settings({ 'groups_ignore' => 'true', 'msg_call' => '  Hola  ', 'unknown' => 'x' })

      expect(result).to eq({ success: true, message: 'ok' })
      expect(
        set_stub.with do |req|
          body = JSON.parse(req.body)
          body['groupsIgnore'] == true && body['msgCall'] == 'Hola' && body['syncFullHistory'] == true &&
            body['wavoipToken'] == 'wav-token' && body['rejectCall'] == true && !body.key?('unknown')
        end
      ).to have_been_requested
    end

    it 'does not save over settings it could not read' do
      stub_request(:get, find_url).to_return(status: 502, body: '')
      set_stub = stub_request(:post, set_url)

      expect(service.update_instance_settings({ 'groups_ignore' => true })).to eq({ success: false, message: 'http_502' })
      expect(set_stub).not_to have_been_requested
    end
  end
end
