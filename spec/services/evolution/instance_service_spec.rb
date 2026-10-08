require 'rails_helper'

describe Evolution::InstanceService do
  subject(:service) { described_class.new(account: account, user: user) }

  let(:account) { create(:account) }
  let(:user) { create(:user, account: account, role: :administrator) }
  let(:create_url) { 'https://evo.example.com/instance/create' }
  let(:evolution_url) { 'https://evo.example.com' }
  let(:evolution_key) { 'GLOBAL-KEY' }

  before do
    allow(GlobalConfigService).to receive(:load).and_call_original
    allow(GlobalConfigService).to receive(:load).with('EVOLUTION_API_URL', '').and_return(evolution_url)
    allow(GlobalConfigService).to receive(:load).with('EVOLUTION_API_KEY', '').and_return(evolution_key)
    allow(GlobalConfigService).to receive(:load).with('EVOLUTION_CHATWOOT_URL', '').and_return('https://chat.example.com')
    # Evita SsrfFilter (resuelve DNS de verdad) y deja el request en Net::HTTP,
    # que es lo que WebMock intercepta.
    allow(ENV).to receive(:fetch).and_call_original
    allow(ENV).to receive(:fetch).with('EVOLUTION_ALLOW_PRIVATE_NETWORK', 'false').and_return('true')
  end

  def stub_create(status: 201, body: nil)
    body ||= { 'hash' => 'INSTANCE-TOKEN', 'chatwoot' => { 'webhookUrl' => 'https://evo.example.com/chatwoot/webhook/soporte-x' } }
    stub_request(:post, create_url).to_return(status: status, body: body.to_json, headers: { 'Content-Type' => 'application/json' })
  end

  describe '#create_inbox' do
    it 'creates the instance linked to a new API inbox' do
      stub_create

      inbox = service.create_inbox(name: ' Soporte ')

      expect(inbox).to be_persisted
      expect(inbox.name).to eq('Soporte')
      expect(inbox.channel.webhook_url).to eq('https://evo.example.com/chatwoot/webhook/soporte-x')
      expect(inbox.channel.additional_attributes).to include(
        'evolution_api_key' => 'INSTANCE-TOKEN', 'evolution_managed_instance' => true
      )
    end

    it 'sends the global key and links the instance to the inbox by name' do
      stub_create

      service.create_inbox(name: 'Soporte')

      expect(
        a_request(:post, create_url).with(headers: { 'apikey' => evolution_key }) do |req|
          body = JSON.parse(req.body)
          body['integration'] == 'WHATSAPP-BAILEYS' &&
            body['instanceName'].start_with?('soporte-') &&
            body['chatwootNameInbox'] == 'Soporte' &&
            body['chatwootAutoCreate'] == false &&
            body['chatwootAccountId'] == account.id.to_s &&
            body['chatwootToken'] == user.access_token.token &&
            body['chatwootUrl'] == 'https://chat.example.com'
        end
      ).to have_been_made.once
    end

    it 'rejects a name already used in the account, before calling Evolution' do
      create(:inbox, account: account, name: 'Soporte')

      expect { service.create_inbox(name: 'Soporte') }
        .to raise_error(an_instance_of(described_class::Error).and(having_attributes(code: 'name_taken')))
      expect(a_request(:post, create_url)).not_to have_been_made
    end

    it 'requires a name' do
      expect { service.create_inbox(name: '  ') }
        .to raise_error(an_instance_of(described_class::Error).and(having_attributes(code: 'name_required')))
    end

    context 'when Evolution is not configured' do
      let(:evolution_key) { '' }

      it 'fails without creating anything' do
        expect { service.create_inbox(name: 'Soporte') }
          .to raise_error(an_instance_of(described_class::Error).and(having_attributes(code: 'not_configured')))
        expect(account.inboxes.count).to eq(0)
      end
    end

    it 'does not create the inbox when Evolution rejects the instance' do
      stub_create(status: 401, body: { 'error' => 'Unauthorized' })

      expect { service.create_inbox(name: 'Soporte') }
        .to raise_error(an_instance_of(described_class::Error).and(having_attributes(code: 'evolution_rejected')))
      expect(account.inboxes.count).to eq(0)
    end

    # Una instancia sin bandeja se queda reintentando conectar en Evolution.
    it 'deletes the instance when the inbox cannot be saved' do
      stub_create
      delete_stub = stub_request(:delete, %r{\Ahttps://evo\.example\.com/instance/delete/soporte-})
      allow(account).to receive(:api_channels).and_raise(ActiveRecord::RecordInvalid)

      expect { service.create_inbox(name: 'Soporte') }.to raise_error(ActiveRecord::RecordInvalid)
      expect(delete_stub).to have_been_requested
    end
  end
end
