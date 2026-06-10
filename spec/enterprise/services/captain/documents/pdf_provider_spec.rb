require 'rails_helper'

RSpec.describe Captain::Documents::PdfProvider do
  let(:account) { create(:account) }
  let(:document) { create(:captain_document, account: account) }

  describe '.provider_for / .gemini?' do
    it 'defaults to openai when the account has no enabled model' do
      expect(described_class.provider_for(document)).to eq('openai')
      expect(described_class.gemini?(document)).to be(false)
    end

    it 'returns gemini when the account has an enabled Gemini model' do
      credential = create(:platform_credential, :gemini, account: account)
      create(:platform_credential_model, credential: credential, slug: 'gemini-2.0-flash', kind: 'multimodal', enabled: true)

      expect(described_class.provider_for(document)).to eq('gemini')
      expect(described_class.gemini?(document)).to be(true)
    end

    it 'stays openai when the enabled model is OpenAI' do
      credential = create(:platform_credential, :openai, account: account)
      create(:platform_credential_model, credential: credential, slug: 'gpt-4.1', kind: 'chat', enabled: true)

      expect(described_class.gemini?(document)).to be(false)
    end

    it 'routes to gemini when the account only has a Gemini credential (no enabled model)' do
      create(:platform_credential, :gemini, account: account)

      expect(described_class.provider_for(document)).to eq('gemini')
      expect(described_class.gemini?(document)).to be(true)
    end

    it 'defaults to openai for a nil document' do
      expect(described_class.provider_for(nil)).to eq('openai')
    end
  end

  describe '.resolved_credential' do
    it 'returns nil when the account has no credential' do
      expect(described_class.resolved_credential(document)).to be_nil
    end

    it 'returns the account Gemini credential used for generation' do
      credential = create(:platform_credential, :gemini, account: account)

      expect(described_class.resolved_credential(document)).to eq(credential)
    end
  end

  describe 'explicit model selection (document_faq)' do
    it 'honors the model picked in Captain settings (provider + model)' do
      gemini = create(:platform_credential, :gemini, account: account)
      create(:platform_credential_model, credential: gemini, slug: 'gemini-2.5-flash', kind: 'multimodal', enabled: true)
      # An OpenAI credential also exists, but the explicit choice must win.
      create(:platform_credential, :openai, account: account)
      account.update!(captain_models: { 'document_faq' => 'gemini-2.5-flash' })

      expect(described_class.provider_for(document)).to eq('gemini')
      expect(described_class.resolved_model(document)).to eq('gemini-2.5-flash')
    end

    it 'falls back to the active provider when nothing is selected' do
      create(:platform_credential, :gemini, account: account)

      expect(described_class.provider_for(document)).to eq('gemini')
    end
  end
end
