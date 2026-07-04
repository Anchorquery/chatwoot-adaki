require 'rails_helper'

RSpec.describe Adaki::CampaignApprovalService do
  let(:account) { create(:account) }
  let(:requester) { create(:user, account: account) }
  let(:approver) { create(:user, account: account) }
  let(:campaign) do
    create(:campaign, :whatsapp, account: account).tap { |c| c.update!(requires_approval: true) }
  end

  before do
    # The :whatsapp campaign trait creates a channel_whatsapp, whose
    # validate_provider_config/sync_templates callbacks hit the real 360dialog
    # API unless stubbed.
    stub_request(:post, 'https://waba.360dialog.io/v1/configs/webhook')
    stub_request(:get, 'https://waba.360dialog.io/v1/configs/templates')
  end

  it 'requests approval and marks campaign pending' do
    described_class.new(campaign).request_approval!(requested_by: requester, recipient_count: 50)
    expect(campaign.reload.approval_status).to eq('pending')
  end

  it 'approves and updates status' do
    described_class.new(campaign).request_approval!(requested_by: requester, recipient_count: 50)
    described_class.new(campaign).approve!(approver: approver, note: 'OK')
    expect(campaign.reload.approval_status).to eq('approved')
  end

  it 'rejects requester==approver' do
    described_class.new(campaign).request_approval!(requested_by: requester, recipient_count: 50)
    expect { described_class.new(campaign).approve!(approver: requester) }
      .to raise_error(ActiveRecord::RecordInvalid, /different from requester/)
  end

  it 'raises NotApproved when ensure_approved! and not approved' do
    expect { described_class.new(campaign).ensure_approved! }
      .to raise_error(Adaki::CampaignApprovalService::NotApproved)
  end
end
