require 'rails_helper'

RSpec.describe Captain::CredentialCircuitBreaker do
  let(:account) { create(:account) }

  # Redis state is not auto-cleared between specs in this suite (see
  # docs/reference_local_test_db_setup.md) — explicit cleanup avoids leaking
  # circuit state into unrelated examples.
  after { described_class.close!(account) }

  describe '.open?' do
    it 'is false for an account with no recorded failures' do
      expect(described_class.open?(account)).to be(false)
    end
  end

  describe '.record_failure!' do
    it 'does not open the circuit before the threshold is reached' do
      (described_class::FAILURE_THRESHOLD - 1).times { described_class.record_failure!(account) }

      expect(described_class.open?(account)).to be(false)
    end

    it 'opens the circuit once the threshold is reached' do
      described_class::FAILURE_THRESHOLD.times { described_class.record_failure!(account) }

      expect(described_class.open?(account)).to be(true)
    end

    it 'notifies once when the circuit opens, not again on every subsequent failure while already open' do
      allow(ChatwootExceptionTracker).to receive(:new).and_call_original

      (described_class::FAILURE_THRESHOLD + 2).times { described_class.record_failure!(account) }

      expect(ChatwootExceptionTracker).to have_received(:new).once
    end

    it 'only opens the circuit for the account that actually failed, not every account' do
      other_account = create(:account)

      described_class::FAILURE_THRESHOLD.times { described_class.record_failure!(account) }

      expect(described_class.open?(account)).to be(true)
      expect(described_class.open?(other_account)).to be(false)

      described_class.close!(other_account)
    end
  end

  describe '.record_success!' do
    it 'resets the failure count so a later run of failures needs the full threshold again' do
      (described_class::FAILURE_THRESHOLD - 1).times { described_class.record_failure!(account) }

      described_class.record_success!(account)

      (described_class::FAILURE_THRESHOLD - 1).times { described_class.record_failure!(account) }

      expect(described_class.open?(account)).to be(false)
    end

    it 'closes an already-open circuit' do
      described_class::FAILURE_THRESHOLD.times { described_class.record_failure!(account) }
      expect(described_class.open?(account)).to be(true)

      described_class.record_success!(account)

      expect(described_class.open?(account)).to be(false)
    end
  end

  describe '.close!' do
    it 'closes an open circuit explicitly, independent of the cooldown timer' do
      described_class::FAILURE_THRESHOLD.times { described_class.record_failure!(account) }

      described_class.close!(account)

      expect(described_class.open?(account)).to be(false)
    end

    it 'is a no-op (does not raise) when the circuit was never open' do
      expect { described_class.close!(account) }.not_to raise_error
    end
  end
end
