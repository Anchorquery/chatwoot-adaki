require 'rails_helper'

describe Api::OneoffCampaignService do
  let(:account) { create(:account) }
  let(:label) { create(:label, account: account) }
  let(:channel_api) { create(:channel_api, account: account) }
  let(:inbox) { channel_api.inbox }
  let(:campaign) do
    create(
      :campaign,
      inbox: inbox,
      account: account,
      audience: [{ type: 'Label', id: label.id }]
    )
  end

  describe '#perform' do
    it 'does not raise when the API inbox is missing a webhook URL' do
      channel_api.update!(webhook_url: nil)

      expect do
        described_class.new(campaign: campaign).perform
      end.not_to raise_error
    end

    it 'passes rendered campaign content to the builder' do
      contact = create(:contact, account: account)
      contact.update_labels([label.title])
      contact_inbox = create(:contact_inbox, contact: contact, inbox: inbox)
      builder = instance_double(Campaigns::CampaignConversationBuilder, perform: true)
      template_service = instance_double(Liquid::CampaignTemplateService, call: 'Rendered API campaign message')

      expect(Liquid::CampaignTemplateService).to receive(:new)
        .with(campaign: campaign, contact: contact)
        .and_return(template_service)
      expect(Campaigns::CampaignConversationBuilder).to receive(:new).with(
        contact_inbox_id: contact_inbox.id,
        campaign_display_id: campaign.display_id,
        message_content: 'Rendered API campaign message'
      ).and_return(builder)
      expect(builder).to receive(:perform)

      described_class.new(campaign: campaign).perform

      expect(campaign.reload.completed?).to be true
    end
  end
end
