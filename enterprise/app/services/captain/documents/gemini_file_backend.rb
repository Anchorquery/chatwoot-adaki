# Ensures a document's PDF is available as an ACTIVE Gemini Files API resource and
# returns a reference ({ 'uri', 'mime_type' }) to embed as a `file_data` part.
#
# The file_uri (and its 48h expiry) is cached on the document metadata so repeated
# FAQ generations within the window reuse the same upload instead of re-sending the
# bytes. Used for PDFs too large for Gemini's inline (~20 MB) request limit.
class Captain::Documents::GeminiFileBackend
  # Re-upload a bit before the real 48h expiry to avoid races.
  EXPIRY_SAFETY_MARGIN = 10.minutes

  def initialize(document)
    @document = document
    @account = document&.account
  end

  def file_reference
    cached_reference || upload_and_cache
  end

  private

  def cached_reference
    data = @document.gemini_file
    return nil if data.blank? || data['uri'].blank? || expired?(data['expires_at'])

    { 'uri' => data['uri'], 'mime_type' => data['mime_type'].presence || 'application/pdf' }
  end

  def expired?(expires_at)
    return true if expires_at.blank?

    Time.zone.parse(expires_at.to_s) <= Time.current + EXPIRY_SAFETY_MARGIN
  rescue ArgumentError, TypeError
    true
  end

  def upload_and_cache
    blob = @document.pdf_file.blob
    file = blob.open do |io|
      client.upload(
        io: io,
        byte_size: blob.byte_size,
        mime_type: blob.content_type.presence || 'application/pdf',
        display_name: blob.filename.to_s
      )
    end

    active = client.wait_until_active(file['name'])
    persist(active, blob)
  end

  def persist(file, blob)
    reference = {
      'uri' => file['uri'],
      'mime_type' => file['mimeType'].presence || blob.content_type.presence || 'application/pdf',
      'name' => file['name'],
      'expires_at' => file['expirationTime']
    }
    @document.update!(gemini_file: reference)
    { 'uri' => reference['uri'], 'mime_type' => reference['mime_type'] }
  end

  def client
    @client ||= Captain::Llm::Gemini::FilesClient.new(api_key: api_key, api_base: api_base)
  end

  # Must be the SAME credential the chat (generateContent) resolves to: Gemini
  # Files API uploads are scoped to the API key/project, so a file uploaded with
  # one key is not visible to another.
  def credential
    @credential ||= Platform::Models::CapabilityResolver
                    .resolve(account: @account, kinds: %w[multimodal chat])
                    &.credential
  end

  def api_key
    credential&.secret(:api_key)
  end

  def api_base
    metadata = credential&.metadata
    metadata.is_a?(Hash) ? (metadata['api_base'].presence || metadata[:api_base].presence) : nil
  end
end
