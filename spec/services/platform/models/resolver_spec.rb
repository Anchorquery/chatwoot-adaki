require 'rails_helper'

RSpec.describe Platform::Models::Resolver do
  let(:account) { create(:account) }

  describe '.resolve' do
    it 'returns nil without an account' do
      expect(described_class.resolve(account: nil)).to be_nil
    end

    context 'when an enabled model matches the feature' do
      it 'returns that credential and slug' do
        credential = create(:platform_credential, :gemini, account: account)
        create(:platform_credential_model, credential: credential, slug: 'gemini-3-flash', kind: 'chat', enabled: true)

        result = described_class.resolve(account: account, feature: 'assistant')

        expect(result[:model_slug]).to eq('gemini-3-flash')
        expect(result[:credential]).to eq(credential)
        expect(result[:source]).to eq(:feature)
      end
    end

    context 'when no model is enabled and the only credential is Gemini (fallback)' do
      it 'never pairs the Gemini credential with an OpenAI (gpt-*) slug' do
        credential = create(:platform_credential, :gemini, account: account)

        result = described_class.resolve(account: account, feature: 'assistant', fallback_model: 'gpt-4.1-mini')

        expect(result[:credential]).to eq(credential)
        expect(result[:source]).to eq(:fallback)
        expect(result[:model_slug]).not_to start_with('gpt-')
        expect(Llm::Models.models.dig(result[:model_slug], 'provider')).to eq('gemini')
      end
    end

    context 'when the Gemini credential carries a synced chat model' do
      it 'prefers the synced model slug even if not enabled' do
        credential = create(:platform_credential, :gemini, account: account)
        create(:platform_credential_model, credential: credential, slug: 'gemini-custom-pro', kind: 'chat', enabled: false)

        result = described_class.resolve(account: account, feature: 'assistant')

        expect(result[:model_slug]).to eq('gemini-custom-pro')
        expect(result[:source]).to eq(:fallback)
      end
    end

    context 'when the only credential is OpenAI (fallback)' do
      it 'resolves to an OpenAI-provider slug' do
        credential = create(:platform_credential, :openai, account: account)

        result = described_class.resolve(account: account, feature: 'assistant', fallback_model: 'gpt-4.1-mini')

        expect(result[:credential]).to eq(credential)
        expect(Llm::Models.models.dig(result[:model_slug], 'provider')).to eq('openai')
      end
    end
  end
end
