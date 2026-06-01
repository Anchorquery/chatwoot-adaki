require 'rails_helper'

RSpec.describe Captain::Embeddings::ReindexJob do
  let(:account) { create(:account) }
  let(:assistant) { create(:captain_assistant, account: account) }

  let(:embedding_service) { instance_double(Captain::Llm::EmbeddingService) }
  let(:new_vector) { Array.new(1536) { 0.5 } }

  before do
    allow(Captain::Llm::EmbeddingService).to receive(:new).and_return(embedding_service)
    allow(embedding_service).to receive(:model_name).and_return('gemini-embedding-001')
    allow(embedding_service).to receive(:get_embedding).and_return(new_vector)
  end

  it 're-tags the account responses with the target model and flips the active pointer' do
    response = create(:captain_assistant_response, assistant: assistant, account: account, embedding_model: 'text-embedding-3-small')

    described_class.perform_now(account.id)

    expect(response.reload.embedding_model).to eq('gemini-embedding-001')
    expect(Captain::Embeddings::Manager.active_model(account.reload)).to eq('gemini-embedding-001')
  end

  it 'no-ops when the active model already matches the target' do
    Captain::Embeddings::Manager.set_active!(account, 'gemini-embedding-001')

    expect(embedding_service).not_to receive(:get_embedding)

    described_class.perform_now(account.reload.id)
  end
end
