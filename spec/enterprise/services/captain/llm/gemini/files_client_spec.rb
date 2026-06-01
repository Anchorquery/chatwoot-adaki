require 'rails_helper'

RSpec.describe Captain::Llm::Gemini::FilesClient do
  subject(:client) { described_class.new(api_key: 'test-key') }

  let(:root) { 'https://generativelanguage.googleapis.com' }
  let(:upload_session) { "#{root}/upload/v1beta/files/session-xyz" }

  describe '#upload' do
    before do
      stub_request(:post, "#{root}/upload/v1beta/files")
        .to_return(status: 200, headers: { 'x-goog-upload-url' => upload_session }, body: '')

      stub_request(:post, upload_session)
        .to_return(
          status: 200,
          body: { file: { name: 'files/abc', uri: "#{root}/v1beta/files/abc", state: 'PROCESSING' } }.to_json
        )
    end

    it 'starts a resumable upload and finalizes it, returning the file resource' do
      file = client.upload(io: StringIO.new('%PDF-1.4 bytes'), byte_size: 14, mime_type: 'application/pdf', display_name: 'big.pdf')

      expect(file['name']).to eq('files/abc')
      expect(file['uri']).to eq("#{root}/v1beta/files/abc")
    end

    it 'raises when the session URL is missing' do
      stub_request(:post, "#{root}/upload/v1beta/files").to_return(status: 200, headers: {}, body: '')

      expect do
        client.upload(io: StringIO.new('x'), byte_size: 1, mime_type: 'application/pdf', display_name: 'a.pdf')
      end.to raise_error(described_class::FilesApiError)
    end
  end

  describe '#wait_until_active' do
    it 'returns the file once ACTIVE' do
      stub_request(:get, "#{root}/v1beta/files/abc")
        .to_return(status: 200, body: { name: 'files/abc', state: 'ACTIVE', uri: "#{root}/v1beta/files/abc" }.to_json)

      file = client.wait_until_active('files/abc', timeout: 5, interval: 0)
      expect(file['state']).to eq('ACTIVE')
    end

    it 'raises on FAILED state' do
      stub_request(:get, "#{root}/v1beta/files/abc")
        .to_return(status: 200, body: { name: 'files/abc', state: 'FAILED' }.to_json)

      expect { client.wait_until_active('files/abc', timeout: 5, interval: 0) }
        .to raise_error(described_class::FilesApiError, /processing failed/)
    end
  end
end
