class Adaki::WhatsappTierMonitorJob < ApplicationJob
  queue_as :low

  def perform(channel_id = nil)
    scope = Channel::Whatsapp.where(provider: 'whatsapp_cloud')
    scope = scope.where(id: channel_id) if channel_id.present?

    scope.find_each do |channel|
      Adaki::TierMonitorService.new(channel).perform
    rescue StandardError => e
      Rails.logger.error "[AdakiWhatsappTierMonitorJob] channel=#{channel.id} #{e.class}: #{e.message}"
    end
  end
end
