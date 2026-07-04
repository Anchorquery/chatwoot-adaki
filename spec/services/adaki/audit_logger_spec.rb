require 'rails_helper'

RSpec.describe Adaki::AuditLogger do
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account) }

  describe '.log' do
    it 'creates an append-only entry with hash_chain' do
      entry = described_class.log(account: account, user: user, action: 'test.action', payload: { foo: 'bar' })
      expect(entry).to be_persisted
      expect(entry.hash_chain).to be_present
      expect(entry.previous_hash).to be_nil
    end

    it 'links subsequent entries via hash chain' do
      first  = described_class.log(account: account, action: 'a')
      second = described_class.log(account: account, action: 'b')
      expect(second.previous_hash).to eq(first.hash_chain)
    end

    it 'verifies an intact chain' do
      3.times { |i| described_class.log(account: account, action: "step.#{i}") }
      expect(Adaki::AuditLogEntry.verify_chain!(account)).to be true
    end

    it 'detects tampering' do
      e1 = described_class.log(account: account, action: 'one')
      described_class.log(account: account, action: 'two')
      # update_columns is blocked by the model's own readonly? guard (by design —
      # see Adaki::AuditLogEntry). Simulate an attacker who tampers with the row
      # directly in the DB, bypassing the ActiveRecord instance entirely.
      Adaki::AuditLogEntry.where(id: e1.id).update_all(payload: { tampered: true }) # rubocop:disable Rails/SkipsModelValidations
      expect { Adaki::AuditLogEntry.verify_chain!(account) }.to raise_error(/Tampered/)
    end

    it 'blocks destroy' do
      e = described_class.log(account: account, action: 'x')
      expect { e.destroy }.to raise_error(ActiveRecord::ReadOnlyRecord)
    end
  end
end
