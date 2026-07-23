require 'rails_helper'

RSpec.describe Internal::TriggerDailyScheduledItemsJob do
  subject(:perform_job) { described_class.perform_now }

  it 'enqueues the job' do
    expect { described_class.perform_later }.to have_enqueued_job(described_class)
      .on_queue('scheduled_jobs')
  end

  it 'does not schedule the upstream version-check job (Adaki is a disconnected fork)' do
    allow(Internal::CheckNewVersionsJob).to receive(:set)

    perform_job

    expect(Internal::CheckNewVersionsJob).not_to have_received(:set)
  end
end
