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
        create(:platform_credential_model, credential: credential, slug: 'gemini-3-flash-preview', kind: 'multimodal', enabled: true)

        result = described_class.resolve(account: account, feature: 'assistant')

        expect(result[:model_slug]).to eq('gemini-3-flash-preview')
        expect(result[:credential]).to eq(credential)
        expect(result[:source]).to eq(:feature)
      end

      # Importer#classify_kind stores every Gemini/Claude model as 'multimodal',
      # so a chat-shaped feature that only accepted 'chat' could never match one.
      it 'matches a Gemini model even though the importer stores it as multimodal' do
        credential = create(:platform_credential, :gemini, account: account)
        create(:platform_credential_model, credential: credential, slug: 'gemini-3.5-flash', kind: 'multimodal', enabled: true)

        %w[assistant copilot editor label_suggestion document_faq].each do |feature|
          expect(described_class.resolve(account: account, feature: feature)[:model_slug]).to eq('gemini-3.5-flash')
        end
        expect(described_class.resolve(account: account, kind: 'chat')[:model_slug]).to eq('gemini-3.5-flash')
      end

      it 'keeps a feature to the kinds that can serve it' do
        credential = create(:platform_credential, :openai, account: account)
        create(:platform_credential_model, credential: credential, slug: 'text-embedding-3-small', kind: 'embedding', enabled: true)
        create(:platform_credential_model, credential: credential, slug: 'gpt-5.1', kind: 'chat', enabled: true)

        expect(described_class.resolve(account: account, feature: 'help_center_search')[:model_slug]).to eq('text-embedding-3-small')
        expect(described_class.resolve(account: account, feature: 'assistant')[:model_slug]).to eq('gpt-5.1')
      end
    end

    # The database (synced verbatim from the provider) is the only source of
    # model identity. The catalog must never name a model.
    context 'when the account has credentials but no synced models' do
      it 'returns nil instead of inventing a slug from the catalog' do
        create(:platform_credential, :gemini, account: account)

        expect(described_class.resolve(account: account, feature: 'assistant')).to be_nil
      end

      it 'returns nil even when a fallback_model is offered' do
        create(:platform_credential, :openai, account: account)

        expect(described_class.resolve(account: account, feature: 'assistant', fallback_model: 'gpt-4.1-mini')).to be_nil
      end
    end

    # For callers that route by provider and carry their own per-provider model
    # default (Captain::Documents::PdfProvider).
    context 'with allow_credential_only' do
      it 'returns the credential with no model rather than nil' do
        credential = create(:platform_credential, :gemini, account: account)

        result = described_class.resolve(account: account, feature: 'assistant', allow_credential_only: true)

        expect(result[:credential]).to eq(credential)
        expect(result[:model_slug]).to be_nil
        expect(result[:source]).to eq(:credential_only)
      end

      it 'still prefers a real synced model when there is one' do
        credential = create(:platform_credential, :gemini, account: account)
        create(:platform_credential_model, credential: credential, slug: 'gemini-3.5-flash', kind: 'multimodal', enabled: true)

        result = described_class.resolve(account: account, feature: 'assistant', allow_credential_only: true)

        expect(result[:model_slug]).to eq('gemini-3.5-flash')
        expect(result[:source]).to eq(:feature)
      end

      it 'is off by default, so callers that need a slug get nil' do
        create(:platform_credential, :gemini, account: account)

        expect(described_class.resolve(account: account, feature: 'assistant')).to be_nil
      end
    end

    context 'when the preferred slug has no enabled row' do
      it 'falls through to the feature rather than pairing a catalog slug with a credential' do
        credential = create(:platform_credential, :gemini, account: account)
        create(:platform_credential_model, credential: credential, slug: 'gemini-3.5-flash', kind: 'multimodal', enabled: true)

        result = described_class.resolve(account: account, feature: 'assistant', preferred_slug: 'gemini-3-flash')

        expect(result[:model_slug]).to eq('gemini-3.5-flash')
        expect(result[:source]).to eq(:feature)
      end

      it 'returns nil when nothing else is synced' do
        create(:platform_credential, :gemini, account: account)

        expect(described_class.resolve(account: account, preferred_slug: 'gemini-3-flash')).to be_nil
      end
    end

    context 'when the preferred slug is an enabled row' do
      it 'wins over the feature match' do
        credential = create(:platform_credential, :openai, account: account)
        create(:platform_credential_model, credential: credential, slug: 'gpt-5.1', kind: 'chat', enabled: true)
        create(:platform_credential_model, credential: credential, slug: 'gpt-4.1-mini', kind: 'chat', enabled: true)

        result = described_class.resolve(account: account, feature: 'assistant', preferred_slug: 'gpt-4.1-mini')

        expect(result[:model_slug]).to eq('gpt-4.1-mini')
        expect(result[:source]).to eq(:preferred)
      end

      it 'resolves a stored preference written with the catalog shorthand' do
        credential = create(:platform_credential, :gemini, account: account)
        create(:platform_credential_model, credential: credential, slug: 'gemini-3-flash-preview', kind: 'multimodal', enabled: true)

        result = described_class.resolve(account: account, preferred_slug: 'gemini-3-flash')

        expect(result[:model_slug]).to eq('gemini-3-flash-preview')
        expect(result[:source]).to eq(:preferred)
      end
    end

    context 'when the provider retired the slug stored on the row' do
      it 'routes a stale DeepSeek row to the current V4 model' do
        credential = create(:platform_credential, account: account, provider: 'deepseek')
        create(:platform_credential_model, credential: credential, slug: 'deepseek-reasoner', kind: 'chat', enabled: true)

        result = described_class.resolve(account: account, feature: 'assistant')

        expect(result[:model_slug]).to eq('deepseek-v4-pro')
      end

      it 'routes a retired stored preference to the current V4 model' do
        credential = create(:platform_credential, account: account, provider: 'deepseek')
        create(:platform_credential_model, credential: credential, slug: 'deepseek-v4-pro', kind: 'chat', enabled: true)

        result = described_class.resolve(account: account, preferred_slug: 'deepseek-reasoner')

        expect(result[:model_slug]).to eq('deepseek-v4-pro')
        expect(result[:source]).to eq(:preferred)
      end
    end

    context 'when models are synced but none enabled' do
      it 'uses a synced model rather than naming one the provider may not serve' do
        credential = create(:platform_credential, :gemini, account: account)
        create(:platform_credential_model, credential: credential, slug: 'gemini-custom-pro', kind: 'multimodal', enabled: false)

        result = described_class.resolve(account: account, feature: 'assistant')

        expect(result[:model_slug]).to eq('gemini-custom-pro')
        expect(result[:source]).to eq(:synced)
      end
    end

    context 'with several credentials' do
      it 'prefers the one whose provider has a native runtime adapter' do
        legacy = create(:platform_credential, account: account, provider: 'openrouter')
        supported = create(:platform_credential, :gemini, account: account)
        create(:platform_credential_model, credential: legacy, slug: 'some/legacy-model', kind: 'chat', enabled: true)
        create(:platform_credential_model, credential: supported, slug: 'gemini-3.5-flash', kind: 'multimodal', enabled: true)

        result = described_class.resolve(account: account, feature: 'assistant')

        expect(result[:credential]).to eq(supported)
        expect(result[:model_slug]).to eq('gemini-3.5-flash')
      end

      it 'still resolves an OpenAI-compatible credential when it is the only one' do
        credential = create(:platform_credential, account: account, provider: 'openrouter')
        create(:platform_credential_model, credential: credential, slug: 'some/legacy-model', kind: 'chat', enabled: true)

        result = described_class.resolve(account: account, feature: 'assistant')

        expect(result[:credential]).to eq(credential)
        expect(result[:model_slug]).to eq('some/legacy-model')
      end
    end

    it 'never returns a slug that is not one of the account\'s own synced models' do
      credential = create(:platform_credential, :gemini, account: account)
      create(:platform_credential_model, credential: credential, slug: 'gemini-3.5-flash', kind: 'multimodal', enabled: true)

      %w[assistant copilot editor label_suggestion document_faq audio_transcription help_center_search].each do |feature|
        result = described_class.resolve(account: account, feature: feature)
        expect(result[:model_slug]).to eq('gemini-3.5-flash') if result
      end
    end
  end
end
