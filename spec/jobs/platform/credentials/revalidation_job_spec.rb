require 'rails_helper'

RSpec.describe Platform::Credentials::RevalidationJob, type: :job do
  let(:account) { create(:account) }

  describe '#perform' do
    it 'revalidates every active credential' do
      active = create(:platform_credential, account: account, status: :active)

      expect(Platform::CredentialManager).to receive(:validate!).with(credential: active)

      described_class.perform_now
    end

    it 'revalidates invalid_credential ones too, to catch a rotated key becoming valid again' do
      invalid = create(:platform_credential, account: account, status: :invalid_credential)

      expect(Platform::CredentialManager).to receive(:validate!).with(credential: invalid)

      described_class.perform_now
    end

    it 'does not touch a credential a human explicitly revoked' do
      create(:platform_credential, account: account, status: :revoked)

      expect(Platform::CredentialManager).not_to receive(:validate!)

      described_class.perform_now
    end

    it 'keeps checking the remaining credentials when one fails, then raises a summary' do
      failing = create(:platform_credential, account: account, status: :active)
      healthy = create(:platform_credential, account: account, status: :active)

      allow(Platform::CredentialManager).to receive(:validate!).with(credential: failing).and_raise(StandardError, 'boom')
      allow(Platform::CredentialManager).to receive(:validate!).with(credential: healthy)

      expect { described_class.perform_now }.to raise_error(/Credential revalidation failed for 1 credentials: #{failing.id}/)
      expect(Platform::CredentialManager).to have_received(:validate!).with(credential: healthy)
    end

    it 'does not raise when every credential validates cleanly' do
      create(:platform_credential, account: account, status: :active)
      allow(Platform::CredentialManager).to receive(:validate!)

      expect { described_class.perform_now }.not_to raise_error
    end
  end
end
