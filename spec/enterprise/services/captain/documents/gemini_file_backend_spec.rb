require 'rails_helper'

RSpec.describe Captain::Documents::GeminiFileBackend do
  let(:account) { create(:account) }
  let(:blob) { double('blob', byte_size: 30.megabytes, content_type: 'application/pdf', filename: 'big.pdf') }
  let(:pdf_file) { double('pdf_file', blob: blob) }
  let(:document) { instance_double(Captain::Document, account: account, pdf_file: pdf_file) }
  let(:client) { instance_double(Captain::Llm::Gemini::FilesClient) }

  before do
    credential = create(:platform_credential, :gemini, account: account)
    allow(Platform::Models::CapabilityResolver).to receive(:resolve).and_return(double(credential: credential))
    allow(Captain::Llm::Gemini::FilesClient).to receive(:new).and_return(client)
  end

  describe '#file_reference' do
    context 'when a non-expired reference is cached' do
      before do
        allow(document).to receive(:gemini_file).and_return(
          { 'uri' => 'cached-uri', 'mime_type' => 'application/pdf', 'expires_at' => (Time.current + 5.hours).iso8601 }
        )
      end

      it 'reuses the cached reference without uploading' do
        expect(client).not_to receive(:upload)

        expect(described_class.new(document).file_reference).to eq(
          { 'uri' => 'cached-uri', 'mime_type' => 'application/pdf' }
        )
      end
    end

    context 'when there is no usable cache' do
      before do
        allow(document).to receive(:gemini_file).and_return(nil)
        allow(blob).to receive(:open).and_yield(StringIO.new('bytes'))
        allow(client).to receive(:upload).and_return('name' => 'files/abc')
        allow(client).to receive(:wait_until_active).with('files/abc').and_return(
          'uri' => 'https://gen/files/abc', 'mimeType' => 'application/pdf',
          'name' => 'files/abc', 'expirationTime' => (Time.current + 2.days).iso8601
        )
      end

      it 'uploads, waits for ACTIVE, caches and returns the reference' do
        expect(document).to receive(:update!).with(
          gemini_file: hash_including('uri' => 'https://gen/files/abc', 'name' => 'files/abc')
        )

        expect(described_class.new(document).file_reference).to eq(
          { 'uri' => 'https://gen/files/abc', 'mime_type' => 'application/pdf' }
        )
      end
    end

    context 'when the cached reference is expired' do
      before do
        allow(document).to receive(:gemini_file).and_return(
          { 'uri' => 'old-uri', 'mime_type' => 'application/pdf', 'expires_at' => (Time.current - 1.hour).iso8601 }
        )
        allow(blob).to receive(:open).and_yield(StringIO.new('bytes'))
        allow(client).to receive(:upload).and_return('name' => 'files/new')
        allow(client).to receive(:wait_until_active).and_return(
          'uri' => 'https://gen/files/new', 'mimeType' => 'application/pdf', 'expirationTime' => (Time.current + 2.days).iso8601
        )
        allow(document).to receive(:update!)
      end

      it 're-uploads' do
        expect(client).to receive(:upload)
        expect(described_class.new(document).file_reference['uri']).to eq('https://gen/files/new')
      end
    end
  end
end
