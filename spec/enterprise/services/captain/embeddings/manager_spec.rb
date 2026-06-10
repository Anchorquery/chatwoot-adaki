require 'rails_helper'

RSpec.describe Captain::Embeddings::Manager do
  let(:account) { create(:account) }

  describe '.write_model' do
    it 'defaults to OpenAI text-embedding-3-small' do
      expect(described_class.write_model(account)).to eq('text-embedding-3-small')
    end

    it "uses the account's enabled embedding model when present" do
      credential = create(:platform_credential, :gemini, account: account)
      create(:platform_credential_model, credential: credential, slug: 'gemini-embedding-001', kind: 'embedding', enabled: true)

      expect(described_class.write_model(account)).to eq('gemini-embedding-001')
      expect(described_class.write_target(account).provider).to eq('gemini')
    end

    it "falls back to Gemini's embedding model when only a gemini credential exists (no embedding CredentialModel)" do
      create(:platform_credential, :gemini, account: account)

      target = described_class.write_target(account)

      expect(target.model).to eq('gemini-embedding-001')
      expect(target.provider).to eq('gemini')
    end

    it 'resolves a context+provider for the gemini fallback model on the search path' do
      create(:platform_credential, :gemini, account: account)

      # After a reindex flips ACTIVE_KEY to the fallback model, search must still
      # resolve the gemini credential context (not nil -> global OpenAI config).
      described_class.set_active!(account, 'gemini-embedding-001')
      target = described_class.search_target(account.reload)

      expect(target.model).to eq('gemini-embedding-001')
      expect(target.provider).to eq('gemini')
    end

    it "honors the model explicitly selected in Captain settings (help_center_search)" do
      create(:platform_credential, :gemini, account: account)
      account.update!(captain_models: { 'help_center_search' => 'gemini-embedding-001' })

      target = described_class.write_target(account)

      expect(target.model).to eq('gemini-embedding-001')
      expect(target.provider).to eq('gemini')
    end
  end

  describe '.active_model / .set_active!' do
    it 'defaults to the OpenAI model and persists a new active model' do
      expect(described_class.active_model(account)).to eq('text-embedding-3-small')

      described_class.set_active!(account, 'gemini-embedding-001')

      expect(described_class.active_model(account.reload)).to eq('gemini-embedding-001')
    end
  end

  describe '.scope_to_active' do
    let(:assistant) { create(:captain_assistant, account: account) }

    it 'includes untagged (NULL) rows for the OpenAI default model' do
      tagged = create(:captain_assistant_response, assistant: assistant, account: account, embedding_model: 'text-embedding-3-small')
      untagged = create(:captain_assistant_response, assistant: assistant, account: account, embedding_model: nil)
      gemini = create(:captain_assistant_response, assistant: assistant, account: account, embedding_model: 'gemini-embedding-001')

      scoped = described_class.scope_to_active(Captain::AssistantResponse.all, account)

      expect(scoped).to include(tagged, untagged)
      expect(scoped).not_to include(gemini)
    end

    it 'filters strictly for a non-default active model' do
      described_class.set_active!(account, 'gemini-embedding-001')
      gemini = create(:captain_assistant_response, assistant: assistant, account: account, embedding_model: 'gemini-embedding-001')
      untagged = create(:captain_assistant_response, assistant: assistant, account: account, embedding_model: nil)

      scoped = described_class.scope_to_active(Captain::AssistantResponse.all, account.reload)

      expect(scoped).to include(gemini)
      expect(scoped).not_to include(untagged)
    end
  end

  describe '.reconcile!' do
    it 'enqueues a reindex when the selected model diverges from the active one' do
      credential = create(:platform_credential, :gemini, account: account)
      create(:platform_credential_model, credential: credential, slug: 'gemini-embedding-001', kind: 'embedding', enabled: true)

      expect do
        described_class.reconcile!(account)
      end.to have_enqueued_job(Captain::Embeddings::ReindexJob).with(account.id, 'gemini-embedding-001')
    end

    it 'is a no-op when the selected model equals the active one' do
      expect do
        described_class.reconcile!(account)
      end.not_to have_enqueued_job(Captain::Embeddings::ReindexJob)
    end
  end
end
