class Adaki::MediaIntegrityService
  # Attachment file_types that legitimately have no ActiveStorage blob.
  NON_FILE_TYPES = %w[location contact ig_reel story_mention].freeze

  def initialize(message)
    @message = message
  end

  # Returns attachments whose expected ActiveStorage blob is missing or unreadable.
  def broken_attachments
    @message.attachments.select do |att|
      next false if NON_FILE_TYPES.include?(att.file_type.to_s)
      next true unless att.file.attached?

      !blob_present?(att)
    end
  end

  def healthy?
    broken_attachments.empty?
  end

  # WhatsApp Cloud media URLs from Meta expire in ~5 minutes. Once a message
  # is persisted without its blob, there is no way to fetch the binary again.
  # This method logs the loss for legal trace and tags attachment metadata.
  # It does NOT attempt re-download (impossible by design).
  def record_loss!
    broken = broken_attachments
    return :no_op if broken.empty?

    broken.each do |att|
      att.update_columns(meta: (att.meta || {}).merge('adaki_corrupted' => true, 'adaki_lost_at' => Time.current.iso8601))
    end

    Adaki::AuditLogger.log(
      account: @message.account,
      action: 'whatsapp.media.lost',
      auditable: @message,
      payload: {
        attachment_ids: broken.map(&:id),
        attachment_count: broken.size,
        inbox_id: @message.inbox_id,
        source_id: @message.source_id
      }
    )
    broken.size
  end

  private

  def blob_present?(att)
    return false unless att.file.attached?

    att.file.blob.service.exist?(att.file.blob.key)
  rescue StandardError => e
    Rails.logger.warn "[AdakiMediaIntegrity] blob_check_failed att=#{att.id} error=#{e.message}"
    false
  end
end
