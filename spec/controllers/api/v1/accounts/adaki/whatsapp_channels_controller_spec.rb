require 'rails_helper'

RSpec.describe 'Adaki Whatsapp Channels API', type: :request do
  let(:account) { create(:account) }
  let(:admin) { create(:user, account: account, role: :administrator) }
  let(:agent) { create(:user, account: account, role: :agent) }
  let(:channel) { create(:channel_whatsapp, account: account, validate_provider_config: false, sync_templates: false) }
  let(:inbox) { create(:inbox, account: account, channel: channel) }

  let(:base_path) { "/api/v1/accounts/#{account.id}/adaki/whatsapp_channels" }

  before { inbox }

  describe 'GET index' do
    it 'unauthorized for agent' do
      get base_path, headers: agent.create_new_auth_token, as: :json
      expect(response).to have_http_status(:forbidden).or have_http_status(:unauthorized)
    end

    it 'lists channels with tier fields' do
      channel.update!(messaging_tier: 1, quality_rating: 'GREEN', daily_conversation_limit: 1_000)
      get base_path, headers: admin.create_new_auth_token, as: :json
      expect(response).to have_http_status(:ok)
      body = response.parsed_body
      expect(body.size).to eq(1)
      expect(body.first['messaging_tier']).to eq(1)
      expect(body.first['quality_rating']).to eq('GREEN')
      expect(body.first['daily_conversation_limit']).to eq(1_000)
    end

    it 'tenant isolated' do
      other_account = create(:account)
      other_channel = create(:channel_whatsapp, account: other_account, validate_provider_config: false, sync_templates: false)
      create(:inbox, account: other_account, channel: other_channel)

      get base_path, headers: admin.create_new_auth_token, as: :json
      expect(response.parsed_body.size).to eq(1)
      expect(response.parsed_body.first['id']).to eq(channel.id)
    end
  end

  describe 'POST refresh_tier' do
    it 'invokes TierMonitorService' do
      snapshot = build_stubbed(:adaki_whatsapp_tier_snapshot, channel_whatsapp: channel)
      allow_any_instance_of(Adaki::TierMonitorService).to receive(:perform).and_return(snapshot)

      post "#{base_path}/#{channel.id}/refresh_tier", headers: admin.create_new_auth_token, as: :json
      expect(response).to have_http_status(:ok)
    end
  end

  describe 'POST unlock_tier' do
    it 'unlocks + audit entry' do
      channel.update!(tier_locked: true, tier_lock_reason: 'over_limit')

      expect do
        post "#{base_path}/#{channel.id}/unlock_tier",
             headers: admin.create_new_auth_token, as: :json
      end.to change(Adaki::AuditLogEntry, :count).by(1)
      expect(channel.reload.tier_locked).to be false
      expect(channel.reload.tier_lock_reason).to be_nil
      expect(Adaki::AuditLogEntry.last.action).to eq('whatsapp.tier.unlock')
    end
  end

  describe 'GET snapshots' do
    it 'returns recent snapshots' do
      3.times { create(:adaki_whatsapp_tier_snapshot, channel_whatsapp: channel) }
      get "#{base_path}/tier_snapshots/#{channel.id}",
          headers: admin.create_new_auth_token, as: :json
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.size).to eq(3)
    end

    it 'denies cross-account access' do
      other = create(:account)
      other_channel = create(:channel_whatsapp, account: other, validate_provider_config: false, sync_templates: false)
      create(:inbox, account: other, channel: other_channel)
      create(:adaki_whatsapp_tier_snapshot, channel_whatsapp: other_channel)

      get "#{base_path}/tier_snapshots/#{other_channel.id}",
          headers: admin.create_new_auth_token, as: :json
      expect(response).to have_http_status(:not_found)
    end
  end
end
