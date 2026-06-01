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

    it 'defaults to openai for a nil document' do
      expect(described_class.provider_for(nil)).to eq('openai')
    end
  end
end
