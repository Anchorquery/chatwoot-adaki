require 'rails_helper'

RSpec.describe Platform::Models::CapabilityResolver do
  let(:account) { create(:account) }

  describe '.resolve' do
    it 'returns nil without an account' do
      expect(described_class.resolve(account: nil, kinds: %w[transcription])).to be_nil
    end

    it 'returns nil when no enabled model matches the requested kinds' do
      credential = create(:platform_credential, :gemini, account: account)
      create(:platform_credential_model, credential: credential, slug: 'gemini-3-flash', kind: 'chat', enabled: true)

      expect(described_class.resolve(account: account, kinds: %w[transcription])).to be_nil
    end

    it 'resolves an enabled model of the requested kind and builds its context' do
      credential = create(:platform_credential, :gemini, account: account)
      create(:platform_credential_model, credential: credential, slug: 'gemini-2.0-flash', kind: 'multimodal', enabled: true)

      result = described_class.resolve(account: account, kinds: %w[transcription multimodal])

      expect(result.model_slug).to eq('gemini-2.0-flash')
      expect(result.provider).to eq('gemini')
      expect(result.context.config.gemini_api_key).to eq('AIzaSy-test-gemini-key')
    end

    it 'honors the kinds order as a preference' do
      credential = create(:platform_credential, :openai, account: account)
      create(:platform_credential_model, credential: credential, slug: 'whisper-1', kind: 'transcription', enabled: true)
      create(:platform_credential_model, credential: credential, slug: 'gpt-4o', kind: 'multimodal', enabled: true)

      result = described_class.resolve(account: account, kinds: %w[transcription multimodal])

      expect(result.model_slug).to eq('whisper-1')
    end

    it 'does not fall through to a model of a different kind' do
      credential = create(:platform_credential, :openai, account: account)
      create(:platform_credential_model, credential: credential, slug: 'text-embedding-3-small', kind: 'embedding', enabled: true)

      expect(described_class.resolve(account: account, kinds: %w[chat multimodal])).to be_nil
    end
  end
end
