require 'rails_helper'

RSpec.describe Adaki::TierMonitorService do
  let(:account) { create(:account) }
  let(:channel) do
    create(:channel_whatsapp, account: account,
                              validate_provider_config: false,
                              sync_templates: false)
  end
  let!(:inbox) { create(:inbox, account: account, channel: channel) }

  describe '#safe_to_send?' do
    it 'false when channel tier_locked' do
      channel.update!(tier_locked: true, tier_lock_reason: 'whatever')
      svc = described_class.new(channel)
      allow(svc).to receive(:refresh_if_stale!)
      expect(svc.safe_to_send?(10)).to be false
    end

    it 'true when no daily limit set' do
      channel.update!(daily_conversation_limit: nil, tier_checked_at: Time.current)
      svc = described_class.new(channel)
      allow(svc).to receive(:refresh_if_stale!)
      expect(svc.safe_to_send?(10)).to be true
    end

    it 'true when usage + recipients under 95% threshold' do
      channel.update!(daily_conversation_limit: 1_000, tier_checked_at: Time.current)
      create(:adaki_whatsapp_tier_snapshot, channel_whatsapp: channel,
                                            conversations_sent_24h: 100,
                                            max_daily_conversations: 1_000)
      svc = described_class.new(channel)
      allow(svc).to receive(:refresh_if_stale!)
      expect(svc.safe_to_send?(800)).to be true
    end

    it 'false when usage + recipients would breach 95%' do
      channel.update!(daily_conversation_limit: 1_000, tier_checked_at: Time.current)
      create(:adaki_whatsapp_tier_snapshot, channel_whatsapp: channel,
                                            conversations_sent_24h: 900,
                                            max_daily_conversations: 1_000)
      svc = described_class.new(channel)
      allow(svc).to receive(:refresh_if_stale!)
      expect(svc.safe_to_send?(60)).to be false
    end
  end

  describe '#perform' do
    let(:meta) do
      {
        'messaging_limit_tier' => 'TIER_1K',
        'quality_rating' => 'GREEN',
        'conversations_sent_24h' => 100,
        'status' => 'CONNECTED'
      }
    end

    before do
      svc = described_class.new(channel)
      allow(svc).to receive(:fetch_phone_number_metadata).and_return(meta)
      @svc = svc
    end

    it 'creates snapshot and updates channel' do
      expect { @svc.perform }.to change(Adaki::WhatsappTierSnapshot, :count).by(1)
      expect(channel.reload.messaging_tier).to eq(3)
      expect(channel.daily_conversation_limit).to eq(1_000)
      expect(channel.quality_rating).to eq('GREEN')
    end

    it 'locks on RED quality' do
      meta['quality_rating'] = 'RED'
      expect { @svc.perform }.to change(Adaki::AuditLogEntry, :count).by_at_least(1)
      expect(channel.reload.tier_locked).to be true
      expect(channel.tier_lock_reason).to eq('quality_rating_red')
    end

    it 'locks at 95% daily usage' do
      meta['conversations_sent_24h'] = 980
      @svc.perform
      expect(channel.reload.tier_locked).to be true
      expect(channel.tier_lock_reason).to eq('daily_limit_near_exhaustion')
    end

    it 'no lock at 75% (warning only)' do
      meta['conversations_sent_24h'] = 800
      @svc.perform
      expect(channel.reload.tier_locked).to be false
    end

    it 'returns nil and logs when network fails' do
      svc = described_class.new(channel)
      allow(svc).to receive(:fetch_phone_number_metadata).and_raise(StandardError, 'boom')
      expect(svc.perform).to be_nil
    end
  end
end
