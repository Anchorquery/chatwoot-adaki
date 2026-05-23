class Api::V1::Accounts::Adaki::WhatsappChannelsController < Api::V1::Accounts::BaseController
  before_action :fetch_channel, only: [:refresh_tier, :unlock_tier]
  before_action :check_admin_authorization?

  def index
    channels = Channel::Whatsapp.joins(:inbox).where(inboxes: { account_id: Current.account.id })
    render json: channels.map { |c| serialize_channel(c) }
  end

  def refresh_tier
    snapshot = Adaki::TierMonitorService.new(@channel).perform
    render json: snapshot
  end

  def unlock_tier
    @channel.update!(tier_locked: false, tier_lock_reason: nil)
    Adaki::AuditLogger.log(
      account: Current.account,
      user: Current.user,
      action: 'whatsapp.tier.unlock',
      payload: { channel_id: @channel.id }
    )
    render json: serialize_channel(@channel)
  end

  def snapshots
    # Tenant boundary: validate channel belongs to Current.account before exposing snapshots.
    channel = Channel::Whatsapp.joins(:inbox)
                               .where(inboxes: { account_id: Current.account.id })
                               .find(params[:channel_id])
    snapshots = Adaki::WhatsappTierSnapshot.where(channel_whatsapp_id: channel.id)
                                           .order(captured_at: :desc).limit(100)
    render json: snapshots
  end

  private

  def fetch_channel
    @channel = Channel::Whatsapp.joins(:inbox).where(inboxes: { account_id: Current.account.id }).find(params[:id])
  end

  def serialize_channel(channel)
    {
      id: channel.id,
      phone_number: channel.phone_number,
      provider: channel.provider,
      messaging_tier: channel.messaging_tier,
      quality_rating: channel.quality_rating,
      daily_conversation_limit: channel.daily_conversation_limit,
      tier_checked_at: channel.tier_checked_at,
      tier_locked: channel.tier_locked,
      tier_lock_reason: channel.tier_lock_reason
    }
  end
end
