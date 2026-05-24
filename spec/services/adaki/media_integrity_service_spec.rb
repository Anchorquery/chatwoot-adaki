require 'rails_helper'

RSpec.describe Adaki::MediaIntegrityService do
  let(:account) { create(:account) }
  let(:inbox) { create(:inbox, account: account) }
  let(:conversation) { create(:conversation, account: account, inbox: inbox) }
  let(:message) { create(:message, account: account, inbox: inbox, conversation: conversation) }

  describe '#healthy?' do
    it 'true when no attachments' do
      expect(described_class.new(message).healthy?).to be true
    end

    it 'ignores location/contact attachments (no blob expected)' do
      message.attachments.create!(account: account, file_type: :location)
      message.attachments.create!(account: account, file_type: :contact)
      expect(described_class.new(message).healthy?).to be true
    end

    it 'flags attachment without attached file' do
      message.attachments.create!(account: account, file_type: :image, external_url: 'http://example/x.jpg')
      expect(described_class.new(message).healthy?).to be false
    end
  end

  describe '#record_loss!' do
    it 'noop when healthy' do
      expect(described_class.new(message).record_loss!).to eq(:no_op)
    end

    it 'marks attachment meta and writes audit when broken' do
      att = message.attachments.create!(account: account, file_type: :image, external_url: 'http://example/x.jpg')

      expect do
        described_class.new(message).record_loss!
      end.to change(Adaki::AuditLogEntry, :count).by(1)

      att.reload
      expect(att.meta['adaki_corrupted']).to be true
      expect(att.meta['adaki_lost_at']).to be_present
      expect(Adaki::AuditLogEntry.last.action).to eq('whatsapp.media.lost')
    end
  end
end
