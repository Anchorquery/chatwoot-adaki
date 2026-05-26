class Campaigns::ProcessBatchJob < ApplicationJob
  queue_as :low

  def perform(campaign)
    return unless campaign.running?

    state = campaign.delivery_state.to_h.with_indifferent_access
    state[:sent_count] = state[:sent_count].to_i
    state[:failed_count] = state[:failed_count].to_i
    state[:consecutive_failures] = state[:consecutive_failures].to_i
    state[:processed_index] = state[:processed_index].to_i
    state[:errors] = Array(state[:errors])

    batch_size = [(campaign.delivery_settings.to_h.with_indifferent_access[:batch_size] || 10).to_i, 1].max
    contact_ids = state[:contact_ids] || []
    start_index = state[:processed_index]
    end_index = [start_index + batch_size, contact_ids.size].min

    (start_index...end_index).each do |idx|
      break unless campaign.reload.running?

      contact_id = contact_ids[idx]
      contact = campaign.account.contacts.find(contact_id)
      contact_inbox = campaign.inbox.contact_inboxes.find_by(contact: contact)

      if contact_inbox.nil?
        persist_state(campaign, processed_index: idx + 1)
        next
      end

      message_content = select_message_content(campaign, contact)

      begin
        conversation = ::Conversation.create!(
          account_id: campaign.account_id,
          inbox_id: campaign.inbox_id,
          contact_id: contact.id,
          contact_inbox_id: contact_inbox.id,
          campaign_id: campaign.id
        )

        ::Messages::MessageBuilder.new(campaign.sender, conversation, {
          content: message_content,
          campaign_id: campaign.id,
          attachments: campaign.attachments.map { |attachment| attachment.blob.signed_id }
        }).perform

        state = increment_state(campaign, sent_count: 1, consecutive_failures: 0, processed_index: idx + 1)
      rescue StandardError => e
        state = increment_state(
          campaign,
          failed_count: 1,
          consecutive_failures: 1,
          processed_index: idx + 1,
          errors: [{ contact_id: contact_id, error: e.message, time: Time.current }]
        )

        if state[:consecutive_failures].to_i >= 5
          campaign.paused!
          persist_state(campaign, errors: Array(state[:errors]) + [{ system: 'Campaign auto-paused because of repeated failures', time: Time.current }])
          return
        end
      end
    end

    campaign.completed! if state[:processed_index].to_i >= contact_ids.size
    Campaigns::ProcessBatchJob.perform_later(campaign) if state[:processed_index].to_i < contact_ids.size
  end

  private

  def select_message_content(campaign, contact)
    variants = campaign.delivery_settings&.dig('content_variants')
    text = if variants.present? && variants.is_a?(Array)
             variants.sample&.dig('text').presence || campaign.message
           else
             campaign.message
           end

    Liquid::CampaignTemplateService.new(campaign: campaign, contact: contact).call(text)
  end

  def increment_state(campaign, updates)
    persist_state(campaign, updates)
  end

  def persist_state(campaign, updates)
    campaign.with_lock do
      current_state = campaign.delivery_state.to_h.with_indifferent_access
      current_state[:sent_count] = current_state[:sent_count].to_i
      current_state[:failed_count] = current_state[:failed_count].to_i
      current_state[:consecutive_failures] = current_state[:consecutive_failures].to_i
      current_state[:processed_index] = current_state[:processed_index].to_i
      current_state[:errors] = Array(current_state[:errors])

      current_state[:sent_count] += updates[:sent_count].to_i if updates.key?(:sent_count)
      current_state[:failed_count] += updates[:failed_count].to_i if updates.key?(:failed_count)
      current_state[:consecutive_failures] = updates[:consecutive_failures] if updates.key?(:consecutive_failures)
      current_state[:processed_index] = updates[:processed_index] if updates.key?(:processed_index)
      current_state[:errors] += Array(updates[:errors]) if updates.key?(:errors)

      campaign.update!(delivery_state: current_state)
      current_state
    end
  end
end
