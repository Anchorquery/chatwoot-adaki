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

  def stub_pdf(byte_size:)
    pdf_file = double('pdf_file', attached?: true, blob: double('blob', byte_size: byte_size))
    allow(document).to receive(:pdf_file).and_return(pdf_file)
  end

  context 'when the document has no attached PDF' do
    it 'returns an empty array' do
      expect(described_class.new(document).generate).to eq([])
    end
  end

  context 'with a small PDF (inline path)' do
    before { stub_pdf(byte_size: 1.megabyte) }

    it 'sends the PDF inline and parses the faqs' do
      service = described_class.new(document)
      chat = stub_chat_returning('{"faqs": [{"question": "Q1", "answer": "A1"}]}')
      allow(service).to receive(:chat).and_return(chat)

      expect(chat).to receive(:ask).with(described_class::USER_PROMPT, with: document.pdf_file)
                                   .and_return(double(content: '{"faqs": []}'))

      service.generate
    end

    it 'returns [] on invalid JSON' do
      service = described_class.new(document)
      allow(service).to receive(:chat).and_return(stub_chat_returning('not json'))

      expect(service.generate).to eq([])
    end
  end

  context 'with a large PDF (Files API path)' do
    before do
      stub_pdf(byte_size: 30.megabytes)
      backend = instance_double(Captain::Documents::GeminiFileBackend)
      allow(Captain::Documents::GeminiFileBackend).to receive(:new).and_return(backend)
      allow(backend).to receive(:file_reference).and_return(
        { 'uri' => 'https://gen.googleapis.com/v1beta/files/abc', 'mime_type' => 'application/pdf' }
      )
    end

    it 'references the uploaded file via a raw file_data part' do
      service = described_class.new(document)
      chat = stub_chat_returning('{"faqs": [{"question": "Q", "answer": "A"}]}')
      allow(service).to receive(:chat).and_return(chat)

      expect(chat).to receive(:ask) do |content|
        expect(content).to be_a(RubyLLM::Content::Raw)
        parts = content.value
        expect(parts.first[:file_data][:file_uri]).to eq('https://gen.googleapis.com/v1beta/files/abc')
        double(content: '{"faqs": []}')
      end

      service.generate
    end
  end

  describe 'provider resolution' do
    it 'resolves the account multimodal Gemini model' do
      credential = create(:platform_credential, :gemini, account: account)
      create(:platform_credential_model, credential: credential, slug: 'gemini-2.0-flash', kind: 'multimodal', enabled: true)

      service = described_class.new(document)

      expect(service.instance_variable_get(:@model)).to eq('gemini-2.0-flash')
      expect(service.instance_variable_get(:@resolved_credential)).to eq(credential)
    end

    it 'honors the model explicitly selected in Captain settings' do
      credential = create(:platform_credential, :gemini, account: account)
      create(:platform_credential_model, credential: credential, slug: 'gemini-2.5-pro', kind: 'multimodal', enabled: true)
      create(:platform_credential_model, credential: credential, slug: 'gemini-2.0-flash', kind: 'multimodal', enabled: true)
      account.update!(captain_models: { 'document_faq' => 'gemini-2.5-pro' })

      service = described_class.new(document)

      expect(service.instance_variable_get(:@model)).to eq('gemini-2.5-pro')
    end
  end
end
