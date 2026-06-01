# Minimal client for Google's Gemini Files API (https://ai.google.dev/gemini-api/docs/files).
#
# RubyLLM only sends files inline (base64), which caps the request at ~20 MB.
# For larger PDFs we upload to the Files API once and reference the returned
# file_uri in generateContent (analogous to OpenAI's Files API). Uploaded files
# live for 48h and can be up to 2 GB.
#
# Uses the resumable upload protocol (robust for large files) and the same API
# key/base as the account's resolved Gemini credential.
class Captain::Llm::Gemini::FilesClient
  class FilesApiError < StandardError; end

  ACTIVE = 'ACTIVE'.freeze
  FAILED = 'FAILED'.freeze
  DEFAULT_BASE = 'https://generativelanguage.googleapis.com/v1beta'.freeze

  def initialize(api_key:, api_base: nil)
    raise ArgumentError, 'api_key is required' if api_key.blank?

    @api_key = api_key
    @version_base = (api_base.presence || DEFAULT_BASE).chomp('/')
    # Upload endpoint lives under /upload/<version>/files, e.g.
    # https://generativelanguage.googleapis.com/upload/v1beta/files
    @root = @version_base.sub(%r{/v1beta\z}, '')
  end

  # Uploads bytes and returns the File resource hash ({ 'name', 'uri', 'state', ... }).
  def upload(io:, byte_size:, mime_type:, display_name:)
    upload_url = start_resumable(byte_size, mime_type, display_name)
    finalize_upload(upload_url, io, byte_size)
  end

  # Polls the file until it becomes ACTIVE (PDFs need server-side processing).
  def wait_until_active(name, timeout: 90, interval: 2)
    deadline = Time.current + timeout
    loop do
      file = get_file(name)
      state = file['state']
      return file if state == ACTIVE
      raise FilesApiError, "Gemini file #{name} processing failed" if state == FAILED
      raise FilesApiError, "Timed out waiting for Gemini file #{name} to become active" if Time.current > deadline

      sleep(interval)
    end
  end

  def get_file(name)
    id = name.to_s.sub(%r{\Afiles/}, '')
    response = connection.get("#{@version_base}/files/#{id}") do |req|
      req.headers['x-goog-api-key'] = @api_key
    end
    raise FilesApiError, "Failed to fetch Gemini file (#{response.status})" unless response.success?

    data = parse(response)
    data['file'] || data
  end

  private

  def start_resumable(byte_size, mime_type, display_name)
    response = connection.post("#{@root}/upload/v1beta/files") do |req|
      req.headers['x-goog-api-key'] = @api_key
      req.headers['X-Goog-Upload-Protocol'] = 'resumable'
      req.headers['X-Goog-Upload-Command'] = 'start'
      req.headers['X-Goog-Upload-Header-Content-Length'] = byte_size.to_s
      req.headers['X-Goog-Upload-Header-Content-Type'] = mime_type
      req.headers['Content-Type'] = 'application/json'
      req.body = { file: { display_name: display_name } }.to_json
    end
    raise FilesApiError, "Failed to start Gemini upload (#{response.status})" unless response.success?

    url = response.headers['x-goog-upload-url']
    raise FilesApiError, 'Gemini upload session URL missing' if url.blank?

    url
  end

  def finalize_upload(upload_url, io, byte_size)
    io.rewind if io.respond_to?(:rewind)
    response = connection.post(upload_url) do |req|
      req.headers['Content-Type'] = 'application/octet-stream'
      req.headers['Content-Length'] = byte_size.to_s
      req.headers['X-Goog-Upload-Offset'] = '0'
      req.headers['X-Goog-Upload-Command'] = 'upload, finalize'
      req.body = io.read
    end
    raise FilesApiError, "Failed to upload to Gemini (#{response.status})" unless response.success?

    data = parse(response)
    data['file'] || data
  end

  def connection
    @connection ||= Faraday.new do |faraday|
      faraday.options.timeout = 300
      faraday.options.open_timeout = 30
      faraday.adapter Faraday.default_adapter
    end
  end

  def parse(response)
    JSON.parse(response.body.to_s)
  rescue JSON::ParserError
    raise FilesApiError, "Invalid Gemini Files API response: #{response.body.to_s.truncate(200)}"
  end
end
