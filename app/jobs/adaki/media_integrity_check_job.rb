class Adaki::MediaIntegrityCheckJob < ApplicationJob
  queue_as :low

  def perform(message_id)
    message = Message.find_by(id: message_id)
    return if message.blank? || message.attachments.empty?

    service = Adaki::MediaIntegrityService.new(message)
    return if service.healthy?

    lost = service.record_loss!
    Rails.logger.warn "[AdakiMediaIntegrityCheckJob] message=#{message_id} lost_attachments=#{lost}"
  end
end
