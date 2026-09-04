require 'rails_helper'

RSpec.describe Platform::Models::Resolver do
  let(:account) { create(:account) }

  describe '.resolve' do
    it 'uses the module-scoped runtime provider allowlist without raising' do
      expect { described_class.resolve(account: account, feature: 'assistant') }.not_to raise_error
      expect(Llm::Config::SUPPORTED_RUNTIME_PROVIDERS).to include('openai', 'gemini', 'deepseek')
    end

    it 'returns nil without an account' do
      expect(described_class.resolve(account: nil)).to be_nil
    end

    context 'when an enabled model matches the feature' do
      it 'returns that credential and slug' do
        credential = create(:platform_credential, :gemini, account: account)
        create(:platform_credential_model, credential: credential, slug: 'gemini-3-flash-preview', kind: 'chat', enabled: true)

        result = described_class.resolve(account: account, feature: 'assistant')

        expect(result[:model_slug]).to eq('gemini-3-flash-preview')
        expect(result[:credential]).to eq(credential)
        expect(result[:source]).to eq(:feature)
      end
    end

    context 'when the preferred slug is a catalog model with no enabled row but a matching active credential' do
      # Regression: this path reads Llm::Config::SUPPORTED_RUNTIME_PROVIDERS. While
      # that constant lived inside `class << self` the lookup raised NameError and
      # every Captain V2 run ended in an instant handoff (2026-09-04, account 3).
      it 'pairs the catalog slug with the credential of the same provider' do
        credential = create(:platform_credential, :gemini, account: account)

        result = described_class.resolve(account: account, feature: 'assistant', preferred_slug: 'gemini-3-flash')

        expect(result[:credential]).to eq(credential)
        expect(result[:model_slug]).to eq('gemini-3-flash-preview')
        expect(result[:source]).to eq(:preferred_catalog)
      end

      it 'does not pair the slug with a credential of another provider' do
        create(:platform_credential, :openai, account: account)

        result = described_class.resolve(account: account, preferred_slug: 'gemini-3-flash-preview')

        expect(result[:source]).to eq(:fallback)
        expect(result[:model_slug]).not_to eq('gemini-3-flash-preview')
      end
    end

    context 'when the only credential belongs to a provider without a runtime adapter' do
      it 'still resolves it (legacy OpenAI-compatible routing) instead of returning nil' do
        credential = create(:platform_credential, account: account, provider: 'openrouter')

        result = described_class.resolve(account: account, feature: 'assistant')

        expect(result[:credential]).to eq(credential)
        expect(result[:source]).to eq(:fallback)
      end

      it 'prefers a supported provider when both kinds of credentials exist' do
        create(:platform_credential, account: account, provider: 'openrouter')
        supported = create(:platform_credential, :gemini, account: account)

        result = described_class.resolve(account: account, feature: 'assistant')

        expect(result[:credential]).to eq(supported)
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

    context 'when the account still stores a retired DeepSeek alias' do
      it 'routes the preference to the current V4 model' do
        credential = create(:platform_credential, account: account, provider: 'deepseek')

        result = described_class.resolve(
          account: account,
          feature: 'assistant',
          preferred_slug: 'deepseek-reasoner'
        )

        expect(result[:credential]).to eq(credential)
        expect(result[:model_slug]).to eq('deepseek-v4-pro')
        expect(result[:source]).to eq(:preferred_catalog)
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

    context 'when no native runtime credential exists' do
      it 'keeps the first active credential as a legacy fallback' do
        credential = create(:platform_credential, account: account, provider: 'anthropic')

        result = described_class.resolve(account: account, feature: 'assistant')

        expect(result[:credential]).to eq(credential)
        expect(result[:source]).to eq(:fallback)
      end
    end
  end
end
