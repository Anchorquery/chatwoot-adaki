require 'rails_helper'

RSpec.describe Adaki::AbsenceResolver do
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account) }
  let(:cover) { create(:user, account: account) }

  it 'returns the user when no absence active' do
    expect(described_class.new(user).effective_assignee).to eq(user)
  end

  it 'returns coverage user when absence active' do
    create(:adaki_absence, account: account, user: user, coverage_user: cover,
                           start_at: 1.hour.ago, end_at: 1.hour.from_now, status: 'active')
    expect(described_class.new(user).effective_assignee).to eq(cover)
  end

  it 'falls back to user when no coverage assigned' do
    create(:adaki_absence, account: account, user: user, coverage_user: nil,
                           start_at: 1.hour.ago, end_at: 1.hour.from_now, status: 'active')
    expect(described_class.new(user).effective_assignee).to eq(user)
  end
end
