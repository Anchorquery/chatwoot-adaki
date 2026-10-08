require 'rails_helper'

describe Evolution::PrivacyDirectoryService do
  subject(:service) { described_class.new(inbox: inbox, include_evolution: include_evolution) }

  let(:account) { create(:account) }
  let(:channel) do
    create(:channel_api, account: account, webhook_url: 'https://evo.example.com/chatwoot/webhook/ventas',
                         additional_attributes: { 'evolution_api_key' => 'token' })
  end
  let(:inbox) { create(:inbox, account: account, channel: channel) }
  let(:include_evolution) { true }
  let(:find_contacts_url) { 'https://evo.example.com/chat/findContacts/ventas' }
  let(:find_chats_url) { 'https://evo.example.com/chat/findChats/ventas' }

  before do
    allow(ENV).to receive(:fetch).and_call_original
    allow(ENV).to receive(:fetch).with('EVOLUTION_ALLOW_PRIVATE_NETWORK', 'false').and_return('true')
    Rails.cache.clear
  end

  def json(body)
    { status: 200, body: body.to_json, headers: { 'Content-Type' => 'application/json' } }
  end

  def inbox_contact(attrs)
    contact = create(:contact, account: account, **attrs)
    create(:contact_inbox, contact: contact, inbox: inbox, source_id: SecureRandom.hex(4))
    contact
  end

  describe '#search' do
    # Las dos fuentes se consultan siempre; cada test sobrescribe la que mira.
    before do
      stub_request(:post, find_contacts_url).to_return(json([]))
      stub_request(:post, find_chats_url).to_return(json([]))
    end

    it 'searches the address book of the number and pages through it' do
      stub = stub_request(:post, find_contacts_url)
             .with(body: hash_including('where' => { 'onlySaved' => true, 'search' => 'juan' }, 'offset' => 30, 'page' => 2))
             .to_return(json([{ remoteJid: '34600111222@s.whatsapp.net', remoteJidAlt: nil, pushName: 'Juan' }]))

      result = service.search(query: 'juan', type: 'contact', page: 2)

      expect(stub).to have_been_requested
      expect(result[:items].first).to include(jid: '34600111222@s.whatsapp.net', name: 'Juan', phone: '34600111222')
    end

    # Un chat migrado a "@lid" se guarda por su teléfono: es lo que el admin
    # reconoce y lo que Evolution compara como remoteJidAlt.
    it 'selects the phone JID of a lid chat' do
      stub_request(:post, find_contacts_url).to_return(
        json([{ remoteJid: '2049@lid', remoteJidAlt: '34600999888@s.whatsapp.net', pushName: 'Ana' }])
      )

      expect(service.search(query: '', type: 'contact', page: 1)[:items].first[:jid]).to eq('34600999888@s.whatsapp.net')
    end

    it 'adds the Chatwoot contacts of the inbox and drops duplicates' do
      inbox_contact(name: 'Juan', phone_number: '+34600111222', identifier: '34600111222@s.whatsapp.net')
      inbox_contact(name: 'Juana', phone_number: '+34600333444', identifier: '34600333444@s.whatsapp.net')
      stub_request(:post, find_contacts_url).to_return(
        json([{ remoteJid: '34600111222@s.whatsapp.net', remoteJidAlt: nil, pushName: 'Juan WA' }])
      )

      items = service.search(query: 'juan', type: 'contact', page: 1)[:items]

      expect(items.pluck(:jid)).to contain_exactly('34600111222@s.whatsapp.net', '34600333444@s.whatsapp.net')
      expect(items.find { |item| item[:jid] == '34600111222@s.whatsapp.net' }[:source]).to eq('whatsapp')
    end

    it 'finds Chatwoot contacts by the digits of a formatted number' do
      inbox_contact(name: 'Luis', phone_number: '+34600555666', identifier: '34600555666@s.whatsapp.net')
      stub_request(:post, find_contacts_url).to_return(json([]))

      expect(service.search(query: '+34 600 555', type: 'contact', page: 1)[:items].pluck(:name)).to eq(['Luis'])
    end

    context 'when the user cannot see every chat of the number' do
      let(:include_evolution) { false }

      it 'only searches the contacts that already reached the inbox' do
        inbox_contact(name: 'Juan', phone_number: '+34600111222', identifier: '34600111222@s.whatsapp.net')

        expect(service.search(query: 'juan', type: 'contact', page: 1)[:items].size).to eq(1)
        expect(a_request(:post, find_contacts_url)).not_to have_been_made
      end
    end

    it 'finds both saved contacts and people who wrote without being saved' do
      stub_request(:post, find_contacts_url).to_return(
        json([{ remoteJid: '34600111222@s.whatsapp.net', remoteJidAlt: nil, pushName: 'Juan agenda' }])
      )
      stub_request(:post, find_chats_url).to_return(
        json([
               { remoteJid: '34611000000@s.whatsapp.net', pushName: 'Juan sin agendar' },
               { remoteJid: '34600111222@s.whatsapp.net', pushName: 'Juan agenda' }
             ])
      )

      items = service.search(query: 'juan', type: 'contact', page: 1)[:items]

      expect(items.pluck(:jid)).to eq(['34611000000@s.whatsapp.net', '34600111222@s.whatsapp.net'])
    end

    # Un Evolution sin la búsqueda parcial ignora `search` y devolvería la
    # agenda entera sin filtrar; se reconoce porque no trae remoteJidAlt.
    it 'falls back to searching chats on an Evolution without contact search' do
      stub_request(:post, find_contacts_url).to_return(json([{ remoteJid: '1@s.whatsapp.net', pushName: 'Otro' }]))
      chats = stub_request(:post, find_chats_url).to_return(json([{ remoteJid: '34600111222@s.whatsapp.net', pushName: 'Juan' }]))

      items = service.search(query: 'juan', type: 'contact', page: 1)[:items]

      expect(chats).to have_been_requested
      expect(items.pluck(:name)).to eq(['Juan'])
    end

    it 'filters groups by name' do
      stub_request(:get, 'https://evo.example.com/group/fetchAllGroups/ventas?getParticipants=false').to_return(
        json([{ id: '1@g.us', subject: 'Familia' }, { id: '2@g.us', subject: 'Trabajo' }])
      )

      expect(service.search(query: 'fam', type: 'group', page: 1)[:items].pluck(:jid)).to eq(['1@g.us'])
    end
  end

  describe 'labels' do
    it 'remembers the names picked for the saved JIDs only' do
      service.remember_labels({ '34600111222@s.whatsapp.net' => 'Juan', 'other@s.whatsapp.net' => 'X' }, ['34600111222@s.whatsapp.net'])

      expect(inbox.channel.reload.additional_attributes['evolution_privacy_labels']).to eq('34600111222@s.whatsapp.net' => 'Juan')
    end

    # Filtros guardados con el sistema anterior: sus chats nunca llegaron a
    # Chatwoot. Los nombres se piden a Evolution en un solo lote y se guardan.
    it 'fills in old entries from Evolution once and remembers them' do
      contacts = stub_request(:post, find_contacts_url)
                 .with(body: hash_including('where' => { 'remoteJids' => ['34600111222@s.whatsapp.net', '34655555555@s.whatsapp.net'] }))
                 .to_return(json([
                                   { remoteJid: '34600111222@s.whatsapp.net', remoteJidAlt: nil, pushName: 'Juan' },
                                   { remoteJid: '2049@lid', remoteJidAlt: '34655555555@s.whatsapp.net', pushName: 'Ana' }
                                 ]))
      groups = stub_request(:get, 'https://evo.example.com/group/fetchAllGroups/ventas?getParticipants=false')
               .to_return(json([{ id: '1@g.us', subject: 'Familia' }]))
      jids = ['34600111222@s.whatsapp.net', '34655555555@s.whatsapp.net', '1@g.us']

      expect(service.resolve(jids).transform_values { |label| label[:name] }).to eq(
        '34600111222@s.whatsapp.net' => 'Juan', '34655555555@s.whatsapp.net' => 'Ana', '1@g.us' => 'Familia'
      )

      Rails.cache.clear
      again = described_class.new(inbox: inbox.reload, include_evolution: true).resolve(jids)
      expect(again['1@g.us'][:name]).to eq('Familia')
      expect(contacts).to have_been_requested.once
      expect(groups).to have_been_requested.once
    end

    it 'does not ask Evolution for names on behalf of an agent' do
      described_class.new(inbox: inbox, include_evolution: false).resolve(['34600111222@s.whatsapp.net'])

      expect(a_request(:post, find_contacts_url)).not_to have_been_made
    end

    it 'resolves names from the stored labels and from Chatwoot contacts' do
      service.remember_labels({ '1@g.us' => 'Familia' }, ['1@g.us'])
      inbox_contact(name: 'Juan', phone_number: '+34600111222', identifier: '34600111222@s.whatsapp.net')

      labels = described_class.new(inbox: inbox.reload, include_evolution: false)
                              .resolve(['1@g.us', '34600111222@s.whatsapp.net', '34999@s.whatsapp.net'])

      expect(labels).to eq(
        '1@g.us' => { name: 'Familia', phone: nil },
        '34600111222@s.whatsapp.net' => { name: 'Juan', phone: '34600111222' },
        '34999@s.whatsapp.net' => { name: nil, phone: '34999' }
      )
    end
  end
end
