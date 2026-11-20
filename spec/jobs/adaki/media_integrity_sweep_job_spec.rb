require 'rails_helper'

RSpec.describe Adaki::MediaIntegritySweepJob do
  let(:account) { create(:account) }
  let(:whatsapp_inbox) do
    create(:channel_whatsapp, account: account, sync_templates: false, validate_provider_config: false).inbox
  end
  let(:conversation) { create(:conversation, account: account, inbox: whatsapp_inbox) }

  def message_with_attachments(count:, **attrs)
    message = create(:message, account: account, inbox: whatsapp_inbox, conversation: conversation,
                               message_type: :incoming, **attrs)
    count.times do
      message.attachments.create!(account_id: account.id, file_type: :image,
                                  file: { io: Rails.root.join('spec/assets/avatar.png').open, filename: 'avatar.png' })
    end
    message
  end

  it 'enqueues one check per recent incoming WhatsApp message with attachments' do
    multi = message_with_attachments(count: 2)
    single = message_with_attachments(count: 1)
    message_with_attachments(count: 1, created_at: 2.days.ago)
    create(:message, account: account, inbox: whatsapp_inbox, conversation: conversation, message_type: :incoming)

    expect { described_class.perform_now }
      .to have_enqueued_job(Adaki::MediaIntegrityCheckJob).exactly(2).times

    expect(Adaki::MediaIntegrityCheckJob).to have_been_enqueued.with(multi.id)
    expect(Adaki::MediaIntegrityCheckJob).to have_been_enqueued.with(single.id)
  end
end
