# Transcribes an audio attachment. Provider-aware: routes to the account's
# configured transcription model/credential via RubyLLM (OpenAI Whisper or a
# Gemini multimodal model that transcribes via generateContent). Falls back to
# OpenAI whisper-1 on the account's OpenAI credential (or the global config) when
# no transcription/multimodal model is enabled for the account.
class Messages::AudioTranscriptionService
  include Integrations::LlmInstrumentation

  DEFAULT_MODEL = 'whisper-1'.freeze
  # Whisper's hard limit is 25 MB *decimal* (25_000_000). Kept as a conservative
  # upper bound across providers (Gemini inline audio is also bounded). Long
  # audio keeps the attachment but skips transcription.
  AUDIO_BYTE_LIMIT = 25_000_000

  attr_reader :attachment, :message, :account

  def initialize(attachment)
    Llm::Config.initialize!
    @attachment = attachment
    @message = attachment.message
    @account = message&.account
  end

  def perform
    return { error: 'Transcription limit exceeded' } unless can_transcribe?
    return { error: 'Message not found' } if message.blank?
    return { error: 'Audio too large for transcription' } if audio_too_large?

    transcriptions = transcribe_audio
    Rails.logger.info "Audio transcription successful: #{transcriptions}"
    { success: true, transcriptions: transcriptions }
  rescue RubyLLM::UnauthorizedError, Faraday::UnauthorizedError
    Rails.logger.warn('Skipping audio transcription: LLM provider configuration is invalid or disabled (401).')
    { error: 'LLM provider configuration is invalid or disabled (401)' }
  rescue StandardError => e
    Rails.logger.error("[AudioTranscription] account=#{account&.id} message=#{message&.id}: #{e.class}: #{e.message}")
    { error: e.message }
  end

  private

  def can_transcribe?
    return false unless account&.feature_enabled?('captain_integration')
    return false if account.audio_transcriptions.blank?

    account.usage_limits[:captain][:responses][:current_available].positive?
  end

  def audio_too_large?
    blob = attachment.file&.blob
    return false unless blob

    blob.byte_size > AUDIO_BYTE_LIMIT
  end

  def fetch_audio_file
    blob = attachment.file.blob
    temp_dir = Rails.root.join('tmp/uploads/audio-transcriptions')
    FileUtils.mkdir_p(temp_dir)
    temp_file_name = "#{blob.key}-#{blob.filename}"

    if blob.filename.extension_without_delimiter.blank?
      extension = extension_from_content_type(blob.content_type)
      temp_file_name = "#{temp_file_name}.#{extension}" if extension.present?
    end

    temp_file_path = File.join(temp_dir, temp_file_name)

    File.open(temp_file_path, 'wb') do |file|
      blob.open do |blob_file|
        IO.copy_stream(blob_file, file)
      end
    end

    temp_file_path
  end

  def transcribe_audio
    transcribed_text = attachment.meta&.[]('transcribed_text') || ''
    return transcribed_text if transcribed_text.present?

    temp_file_path = fetch_audio_file

    transcribed_text = instrument_llm_call(instrumentation_params(temp_file_path)) do
      run_transcription(temp_file_path)
    end

    update_transcription(transcribed_text)
    transcribed_text
  ensure
    FileUtils.rm_f(temp_file_path) if temp_file_path.present?
  end

  # temperature: 0.0 minimises Whisper's hallucinations on silence / near-silent
  # audio; non-zero values trigger spiraling repeats ("Oh, dear. Oh, dear.").
  def run_transcription(temp_file_path)
    options = { model: transcription_model, temperature: 0.0 }
    options[:context] = transcription_context if transcription_context

    RubyLLM.transcribe(temp_file_path, **options).text
  end

  def resolved_transcription
    return @resolved_transcription if defined?(@resolved_transcription)

    @resolved_transcription = Platform::Models::CapabilityResolver.resolve(
      account: account,
      kinds: %w[transcription multimodal]
    )
  end

  def transcription_model
    resolved_transcription&.model_slug.presence || DEFAULT_MODEL
  end

  # Per-credential context for the resolved transcription model, or the account's
  # OpenAI credential context for the whisper-1 default (nil -> global config).
  def transcription_context
    return @transcription_context if defined?(@transcription_context)

    @transcription_context = resolved_transcription&.context || openai_fallback_context
  end

  def openai_fallback_context
    credential = Platform::CredentialManager.fetch_optional(
      account: account,
      key: Platform::CredentialManager.default_key_for('openai'),
      provider: 'openai',
      purpose: 'ai_provider'
    )
    Llm::Config.context_for_credential(credential)
  end

  def instrumentation_params(file_path)
    {
      span_name: 'llm.messages.audio_transcription',
      model: transcription_model,
      account_id: account&.id,
      feature_name: 'audio_transcription',
      file_path: file_path
    }
  end

  def update_transcription(transcribed_text)
    return if transcribed_text.blank?

    attachment.update!(meta: { transcribed_text: transcribed_text })
    message.reload.send_update_event
    message.account.increment_response_usage

    return unless ChatwootApp.advanced_search_allowed?

    message.reindex
  end

  def extension_from_content_type(content_type)
    subtype = content_type.to_s.downcase.split(';').first.to_s.split('/').last.to_s
    return if subtype.blank?

    {
      'x-m4a' => 'm4a',
      'x-wav' => 'wav',
      'x-mp3' => 'mp3'
    }.fetch(subtype, subtype)
  end
end
