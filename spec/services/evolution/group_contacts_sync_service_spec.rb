require 'rails_helper'

describe Evolution::GroupContactsSyncService do
  subject(:service) { described_class.new(inbox) }

  let(:account) { create(:account) }
  let(:channel) do
    create(:channel_api, account: account, webhook_url: 'https://evo.example.com/chatwoot/webhook/ventas',
                         additional_attributes: { 'evolution_api_key' => 'token' })
  end
  let(:inbox) { create(:inbox, account: account, channel: channel) }
  let(:groups_url) { 'https://evo.example.com/group/fetchAllGroups/ventas?getParticipants=false' }

  before do
    allow(ENV).to receive(:fetch).and_call_original
    allow(ENV).to receive(:fetch).with('EVOLUTION_ALLOW_PRIVATE_NETWORK', 'false').and_return('true')
  end

  def stub_groups(body, status: 200)
    stub_request(:get, groups_url).to_return(status: status, body: body.to_json, headers: { 'Content-Type' => 'application/json' })
  end

  it 'creates one contact per group, named and identified like Evolution does, linked to the inbox' do
    stub_groups([{ 'id' => '120363000000000001@g.us', 'subject' => 'Equipo ventas' },
                 { 'id' => '120363000000000002@g.us', 'subject' => '' }])

    expect(service.perform).to eq(success: true, total: 2, created: 2, existing: 0, failed: 0)

    named = account.contacts.find_by(identifier: '120363000000000001@g.us')
    expect(named.name).to eq('Equipo ventas (GROUP)')
    expect(named.phone_number).to be_nil
    expect(inbox.contact_inboxes.where(contact: named).count).to eq(1)
    expect(account.contacts.find_by(identifier: '120363000000000002@g.us').name).to eq('120363000000000002@g.us')
  end

  it 'reuses existing group contacts without renaming them or linking them twice' do
    renamed = create(:contact, account: account, identifier: '120363000000000001@g.us', name: 'Ventas (renombrado)')
    create(:contact_inbox, contact: renamed, inbox: inbox, source_id: SecureRandom.uuid)
    stub_groups([{ 'id' => '120363000000000001@g.us', 'subject' => 'Equipo ventas' }])

    expect(service.perform).to include(success: true, created: 0, existing: 1)
    expect(renamed.reload.name).to eq('Ventas (renombrado)')
    expect(inbox.contact_inboxes.where(contact: renamed).count).to eq(1)
  end

  it 'is idempotent' do
    stub_groups([{ 'id' => '120363000000000001@g.us', 'subject' => 'Equipo ventas' }])

    service.perform
    expect { described_class.new(inbox).perform }.not_to change(ContactInbox, :count)
  end

  it 'ignores entries that are not groups' do
    stub_groups([{ 'id' => '34600111222@s.whatsapp.net', 'subject' => 'x' }, nil, 'junk'])

    expect(service.perform).to include(success: true, total: 0)
    expect(account.contacts.count).to eq(0)
  end

  it 'reports the evolution status when the groups cannot be read' do
    stub_groups({ 'error' => 'down' }, status: 500)

    expect(service.perform).to eq(success: false, message: 'http_500')
  end

  context 'when the inbox has no evolution api key' do
    let(:channel) { create(:channel_api, account: account, webhook_url: 'https://evo.example.com/chatwoot/webhook/ventas') }

    it 'reports not_configured' do
      expect(service.perform).to eq(success: false, message: 'not_configured')
    end
  end
end
