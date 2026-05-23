class Adaki::MediaIntegritySweepJob < ApplicationJob
  queue_as :low

  # Sweep recent incoming WhatsApp messages with attachments to catch silent media loss.
  # Pre-resolve distinct message IDs to avoid Rails warning about find_each + distinct.
  def perform(since: 24.hours.ago)
    message_ids = Message.incoming
                         .joins(:attachments, :inbox)
                         .where(inboxes: { channel_type: 'Channel::Whatsapp' })
                         .where(created_at: since..Time.current)
                         .distinct
                         .pluck(:id)

    message_ids.each_slice(200) do |slice|
      slice.each { |mid| Adaki::MediaIntegrityCheckJob.perform_later(mid) }
    end
  end
end
