require 'rails_helper'

RSpec.describe Internal::CheckNewVersionsJob do
  subject(:job) { described_class.perform_now }

  it 'does not ping the upstream Chatwoot hub (Adaki is a disconnected fork)' do
    allow(Rails.env).to receive(:production?).and_return(true)
    allow(ChatwootHub).to receive(:sync_with_hub)
    job
    expect(ChatwootHub).not_to have_received(:sync_with_hub)
  end

  it 'does not store a latest version in redis' do
    job
    expect(Redis::Alfred.get(Redis::Alfred::LATEST_CHATWOOT_VERSION)).to be_nil
  end
end
