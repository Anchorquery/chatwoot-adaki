require 'rails_helper'

RSpec.describe Captain::KnowledgePrefetcher do
  let(:account) { create(:account) }
  let(:assistant) { create(:captain_assistant, account: account) }
  let(:prefetcher) { described_class.new(assistant) }

  before do
    embedding_service = instance_double(Captain::Llm::EmbeddingService)
    allow(Captain::Llm::EmbeddingService).to receive(:new).and_return(embedding_service)
    allow(embedding_service).to receive(:get_embedding).and_return(Array.new(1536, 0.1))
  end

  context 'when the assistant has approved FAQs' do
    let(:document) { create(:captain_document, assistant: assistant, external_link: 'https://example.com/precios') }

    before do
      create(:captain_assistant_response, assistant: assistant, question: '¿Cuánto cuesta el pack de 3?',
                                          answer: '37,90 €', documentable: document, status: 'approved')
      create(:captain_assistant_response, assistant: assistant, question: 'Pendiente', answer: 'no', status: 'pending')
    end

    it 'returns the matching entries formatted like faq_lookup, with their source' do
      result = prefetcher.call('cuánto cuesta el pack de 3 tarjetas')

      expect(result).to include("Question: ¿Cuánto cuesta el pack de 3?\nAnswer: 37,90 €\nSource: https://example.com/precios")
      expect(result).not_to include('Pendiente')
    end

    it 'skips one-word messages such as greetings without embedding anything' do
      expect(prefetcher.call('hola')).to be_nil
      expect(prefetcher.call('  ')).to be_nil
      expect(prefetcher.call(nil)).to be_nil
      expect(Captain::Llm::EmbeddingService).not_to have_received(:new)
    end

    describe '#attach' do
      it 'wraps the entries and the customer message in delimited blocks' do
        result = prefetcher.attach('cuánto cuesta el pack de 3 tarjetas')

        expect(result).to start_with('<knowledge_base_results>')
        expect(result).to include(described_class::INSTRUCTIONS)
        expect(result).to include('Answer: 37,90 €')
        expect(result).to include("<customer_message>\ncuánto cuesta el pack de 3 tarjetas\n</customer_message>")
      end

      it 'returns the message untouched when nothing was retrieved' do
        expect(prefetcher.attach('hola')).to eq('hola')
      end
    end

    it 'never breaks the turn when the search fails' do
      allow(Captain::AssistantResponse).to receive(:search).and_raise(Captain::Llm::EmbeddingService::EmbeddingsError, 'down')

      expect(prefetcher.call('cuánto cuesta el pack')).to be_nil
    end
  end

  it 'returns nil without embedding when the assistant has no approved FAQs' do
    expect(prefetcher.call('cuánto cuesta el pack')).to be_nil
    expect(Captain::Llm::EmbeddingService).not_to have_received(:new)
  end
end
