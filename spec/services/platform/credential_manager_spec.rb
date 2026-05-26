require 'rails_helper'

RSpec.describe Platform::CredentialManager do
  describe '.fetch_optional' do
    it 'falls back to legacy installation config when platform credentials table is unavailable' do
      account = create(:account)
      legacy_credential = {
        provider: 'openai',
        purpose: 'legacy',
        key: 'openai.default',
        name: 'Openai Default',
        auth_type: 'api_key',
        payload: { api_key: 'legacy-key' },
        metadata: {}
      }

      allow(ActiveRecord::Base.connection).to receive(:data_source_exists?)
        .with('platform_credentials')
        .and_return(false)
      expect(Platform::Credential).not_to receive(:where)
      allow(Platform::Credentials::LegacyInstallationConfigAdapter).to receive(:fetch)
        .with('openai.default')
        .and_return(legacy_credential)

      credential = described_class.fetch_optional(
        account: account,
        key: 'openai.default',
        provider: 'openai',
        purpose: 'ai_provider'
      )

      expect(credential).to be_present
      expect(credential.secret(:api_key)).to eq('legacy-key')
    end
  end
end
