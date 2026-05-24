require 'rails_helper'

RSpec.describe Adaki::CaptainUsageTracker do
  let(:account) { create(:account) }

  describe '.enforce_limit!' do
    it 'noop when limit nil' do
      account.update!(adaki_captain_monthly_limit: nil)
      expect { described_class.enforce_limit!(account) }.not_to raise_error
    end

    it 'noop when limit zero' do
      account.update!(adaki_captain_monthly_limit: 0)
      expect { described_class.enforce_limit!(account) }.not_to raise_error
    end

    it 'noop when usage under limit' do
      account.update!(adaki_captain_monthly_limit: 10)
      Adaki::CaptainUsage.current_for(account).update!(request_count: 5)
      expect { described_class.enforce_limit!(account) }.not_to raise_error
    end

    it 'raises LimitExceeded when at limit' do
      account.update!(adaki_captain_monthly_limit: 10)
      Adaki::CaptainUsage.current_for(account).update!(request_count: 10)
      expect { described_class.enforce_limit!(account) }.to raise_error(described_class::LimitExceeded)
    end

    it 'raises LimitExceeded when over limit' do
      account.update!(adaki_captain_monthly_limit: 10)
      Adaki::CaptainUsage.current_for(account).update!(request_count: 50)
      expect { described_class.enforce_limit!(account) }.to raise_error(described_class::LimitExceeded)
    end

    it 'noop when account nil' do
      expect { described_class.enforce_limit!(nil) }.not_to raise_error
    end
  end

  describe '.record!' do
    it 'increments counter and token totals' do
      described_class.record!(account: account, feature: 'assistant', input_tokens: 100, output_tokens: 50)
      usage = Adaki::CaptainUsage.current_for(account)
      expect(usage.request_count).to eq(1)
      expect(usage.input_tokens).to eq(100)
      expect(usage.output_tokens).to eq(50)
    end

    it 'accumulates across calls' do
      3.times do
        described_class.record!(account: account, feature: 'assistant', input_tokens: 10, output_tokens: 5)
      end
      usage = Adaki::CaptainUsage.current_for(account)
      expect(usage.request_count).to eq(3)
      expect(usage.input_tokens).to eq(30)
      expect(usage.output_tokens).to eq(15)
    end

    it 'writes audit entry' do
      user = create(:user, account: account)
      expect do
        described_class.record!(account: account, user: user, feature: 'assistant', input_tokens: 1, output_tokens: 1, assistant_id: 42)
      end.to change(Adaki::AuditLogEntry, :count).by(1)
      entry = Adaki::AuditLogEntry.last
      expect(entry.action).to eq('captain.assistant.invocation')
      expect(entry.payload['assistant_id']).to eq(42)
    end

    it 'noop when account nil' do
      expect { described_class.record!(account: nil, feature: 'assistant') }.not_to raise_error
    end
  end
end
