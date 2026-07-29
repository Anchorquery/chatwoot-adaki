require 'rails_helper'

describe Evolution::AudienceOptionsService do
  subject(:service) { described_class.new(inbox) }

  let(:webhook_url) { 'https://evo.example.com/chatwoot/webhook/miinstancia' }
  let(:additional_attributes) { { 'evolution_api_key' => 'secret-key' } }
  let(:channel) { double(additional_attributes: additional_attributes, webhook_url: webhook_url) } # rubocop:disable RSpec/VerifiedDoubles
  let(:inbox) { double(channel: channel) } # rubocop:disable RSpec/VerifiedDoubles

  let(:find_url) { 'https://evo.example.com/chatwoot/find/miinstancia' }
  let(:set_url) { 'https://evo.example.com/chatwoot/set/miinstancia' }

  before do
    # Evita SsrfFilter (resuelve DNS de verdad) y deja el request en Net::HTTP,
    # que es lo que WebMock intercepta.
    allow(ENV).to receive(:fetch).and_call_original
    allow(ENV).to receive(:fetch).with('EVOLUTION_ALLOW_PRIVATE_NETWORK', 'false').and_return('true')
  end

  def stub_find(body)
    stub_request(:get, find_url).to_return(status: 200, body: body.to_json, headers: { 'Content-Type' => 'application/json' })
  end

  describe '#current_privacy_filter' do
    context 'when the inbox has no evolution api key' do
      let(:additional_attributes) { { 'evolution_api_key' => '' } }

      it 'reports not_configured' do
        expect(service.current_privacy_filter).to eq({ status: 'not_configured' })
      end
    end

    it 'reports unreachable instead of an empty filter when evolution fails' do
      stub_request(:get, find_url).to_return(status: 502, body: '')

      expect(service.current_privacy_filter).to eq({ status: 'unreachable' })
    end

    it 'reports invalid_response when evolution returns junk' do
      stub_request(:get, find_url).to_return(status: 200, body: 'not json')

      expect(service.current_privacy_filter).to eq({ status: 'invalid_response' })
    end

    it 'returns the empty filter when evolution has no lists set' do
      stub_find({ 'ignoreJids' => [], 'allowedJids' => [] })

      expect(service.current_privacy_filter).to eq(
        { status: 'ok', conflict: false, mode: 'all', group_jids: [], channel_jids: [], contact_jids: [] }
      )
    end

    it 'splits jids by suffix' do
      stub_find({ 'allowedJids' => ['1@g.us', '2@newsletter', '3@s.whatsapp.net'] })

      expect(service.current_privacy_filter).to include(
        mode: 'allow',
        group_jids: ['1@g.us'],
        channel_jids: ['2@newsletter'],
        contact_jids: ['3@s.whatsapp.net']
      )
    end

    # Regresión: antes se cruzaban los JIDs guardados contra las listas vivas de
    # Evolution y lo que no apareciera ahí se perdía — el front guardaba lo que
    # veía y lo borraba de Evolution.
    it 'keeps jids that evolution no longer lists, without querying the audience endpoints' do
      stub_find({ 'ignoreJids' => ['99@g.us', '34600111222', '@newsletter'] })

      expect(service.current_privacy_filter).to include(
        mode: 'block',
        group_jids: ['99@g.us'],
        channel_jids: ['@newsletter'],
        contact_jids: ['34600111222']
      )
      expect(a_request(:any, %r{/(group|newsletter|chat)/})).not_to have_been_made
    end

    it 'flags a conflict when evolution has both lists set' do
      stub_find({ 'allowedJids' => ['1@g.us'], 'ignoreJids' => ['2@g.us'] })

      expect(service.current_privacy_filter).to include(mode: 'allow', conflict: true)
    end
  end

  describe '#update_privacy_filter' do
    before { stub_find({ 'enabled' => true, 'accountId' => '1', 'ignoreJids' => ['old@g.us'], 'allowedJids' => [] }) }

    it 'rejects an unknown mode without touching evolution' do
      expect(service.update_privacy_filter(mode: 'nope', jids: [])).to eq({ success: false, message: 'invalid_mode' })
      expect(a_request(:post, set_url)).not_to have_been_made
    end

    it 'writes the allow list and clears the ignore list' do
      stub_request(:post, set_url).to_return(status: 200, body: '{}')

      expect(service.update_privacy_filter(mode: 'allow', jids: ['1@g.us'])).to eq({ success: true, message: 'ok' })
      expect(
        a_request(:post, set_url).with { |req| JSON.parse(req.body).values_at('allowedJids', 'ignoreJids') == [['1@g.us'], []] }
      ).to have_been_made
    end

    it 'reports failure when evolution rejects the write' do
      stub_request(:post, set_url).to_return(status: 401, body: '')

      expect(service.update_privacy_filter(mode: 'block', jids: [])).to eq({ success: false, message: 'http_401' })
    end
  end
end
