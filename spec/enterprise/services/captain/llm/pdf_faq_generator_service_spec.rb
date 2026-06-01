require 'rails_helper'

RSpec.describe Captain::Llm::PdfFaqGeneratorService do
  let(:account) { create(:account) }
  let(:document) { create(:captain_document, account: account) }

  before do
    create(:installation_config, name: 'CAPTAIN_OPEN_AI_API_KEY', value: 'global-key')
    Llm::Config.reset!
  end

  def stub_chat_returning(content)
    chat = double('chat')
    allow(chat).to receive(:with_params).and_return(chat)
    allow(chat).to receive(:with_instructions).and_return(chat)
    allow(chat).to receive(:ask).and_return(double('response', content: content))
    chat
  end

  context 'when the document has no attached PDF' do
    it 'returns an empty array' do
      expect(described_class.new(document).generate).to eq([])
    end
  end

  context 'with an attached PDF' do
    let(:service) { described_class.new(document) }

    before do
      allow(document.pdf_file).to receive(:attached?).and_return(true)
    end

    it 'parses the faqs array from the JSON response' do
      service = described_class.new(document)
      allow(service).to receive(:chat).and_return(
        stub_chat_returning('{"faqs": [{"question": "Q1", "answer": "A1"}]}')
      )

      expect(service.generate).to eq([{ 'question' => 'Q1', 'answer' => 'A1' }])
    end

    it 'returns [] on invalid JSON' do
      service = described_class.new(document)
      allow(service).to receive(:chat).and_return(stub_chat_returning('not json'))

      expect(service.generate).to eq([])
    end
  end

  describe 'provider resolution' do
    it 'resolves the account multimodal Gemini model' do
      credential = create(:platform_credential, :gemini, account: account)
      create(:platform_credential_model, credential: credential, slug: 'gemini-2.0-flash', kind: 'multimodal', enabled: true)

      service = described_class.new(document)

      expect(service.instance_variable_get(:@model)).to eq('gemini-2.0-flash')
      expect(service.send(:resolver_kind)).to eq('multimodal')
    end
  end
end
