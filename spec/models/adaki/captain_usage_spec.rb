require 'rails_helper'

RSpec.describe Adaki::CaptainUsage do
  let(:account) { create(:account) }

  describe '.current_for' do
    it 'creates the current period row when none exists' do
      usage = described_class.current_for(account)

      expect(usage).to be_persisted
      expect(usage.period).to eq(Date.current.beginning_of_month)
    end

    it 'is idempotent across repeated calls' do
      first = described_class.current_for(account)
      second = described_class.current_for(account)

      expect(second).to eq(first)
    end

    # create_or_find_by! (not find_or_create_by!) always attempts create!
    # first, then recovers from ActiveRecord::RecordNotUnique by re-querying
    # — this is what actually closes the race two concurrent Captain
    # responses for the same account can hit against the unique index on
    # [account_id, period]. Reproduced deterministically here since a real
    # two-thread race against a transactional-fixture-wrapped connection
    # isn't reliable in this suite.
    it 'recovers instead of raising when a concurrent insert wins the race' do
      existing = described_class.create!(account_id: account.id, period: Date.current.beginning_of_month)
      allow(described_class).to receive(:create!).and_raise(ActiveRecord::RecordNotUnique.new('duplicate key'))

      expect(described_class.current_for(account)).to eq(existing)
    end
  end
end
