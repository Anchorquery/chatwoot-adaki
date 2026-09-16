require 'rails_helper'

RSpec.describe Captain::Conversation::ScenarioRouter do
  let(:account) { create(:account) }
  let(:assistant) { create(:captain_assistant, account: account) }
  let(:router) { described_class.new(assistant) }

  before do
    embedding_service = instance_double(Captain::Llm::EmbeddingService)
    allow(Captain::Llm::EmbeddingService).to receive(:new).and_return(embedding_service)
    allow(embedding_service).to receive(:get_embedding).and_return(Array.new(1536, 0.1))
  end

  context 'when a scenario is a close match' do
    let!(:refunds) do
      create(:captain_scenario, assistant: assistant, account: account, title: 'Refunds', description: 'Handle refund requests',
                                enabled: true, embedding: Array.new(1536, 0.1))
    end

    it 'returns it' do
      expect(router.route('quiero un reembolso de mi pedido')).to eq(refunds)
    end

    it 'skips disabled scenarios even when they would otherwise match' do
      refunds.update!(enabled: false)

      expect(router.route('quiero un reembolso de mi pedido')).to be_nil
    end

    it 'skips one-word messages such as greetings without embedding anything' do
      expect(router.route('hola')).to be_nil
      expect(router.route('  ')).to be_nil
      expect(router.route(nil)).to be_nil
      expect(Captain::Llm::EmbeddingService).not_to have_received(:new)
    end

    it 'never breaks the turn when the search fails' do
      allow(Captain::Llm::EmbeddingService).to receive(:new).and_raise(StandardError, 'down')

      expect(router.route('quiero un reembolso de mi pedido')).to be_nil
    end
  end

  context 'when no scenario is close enough (distance above the threshold)' do
    before do
      create(:captain_scenario, assistant: assistant, account: account, title: 'Unrelated',
                                description: 'Something else entirely', enabled: true, embedding: Array.new(1536, -0.1))
    end

    it 'returns nil' do
      expect(router.route('quiero un reembolso de mi pedido')).to be_nil
    end

    it 'returns it anyway when the threshold env var is opened all the way up' do
      with_modified_env CAPTAIN_SCENARIO_PREROUTE_DISTANCE_THRESHOLD: '2' do
        expect(router.route('quiero un reembolso de mi pedido')).to be_present
      end
    end
  end

  it 'returns nil without embedding when the assistant has no enabled scenarios with an embedding yet' do
    create(:captain_scenario, assistant: assistant, account: account, enabled: true, embedding: nil)

    expect(router.route('quiero un reembolso de mi pedido')).to be_nil
    expect(Captain::Llm::EmbeddingService).not_to have_received(:new)
  end
end
