# frozen_string_literal: true

# DEPRECATED: This class uses the legacy OpenAI Ruby gem directly.
# Only used for PDF/file operations that require OpenAI's files API:
# - Captain::Llm::PdfProcessingService (files.upload for assistants)
# - Captain::Llm::PaginatedFaqGeneratorService (uses file_id from uploaded files)
#
# These flows remain OpenAI-only on purpose: they depend on the OpenAI Files API
# (upload + file_id references), which Gemini does not provide a drop-in
# equivalent for. Migrating to Gemini's Files API requires rewriting the upload
# flow, not just swapping a credential. Until then this still honors a
# per-account OpenAI credential (passed via `account:`), falling back to the
# global platform credential and finally the legacy InstallationConfig key.
#
# For all other LLM operations, use Llm::BaseAiService with RubyLLM instead.
class Llm::LegacyBaseOpenAiService
  DEFAULT_MODEL = 'gpt-4.1-mini'

  attr_reader :client, :model

  def initialize(account: nil)
    @account = account
    @credential = openai_credential
    @client = OpenAI::Client.new(
      access_token: @credential&.secret(:api_key) || InstallationConfig.find_by!(name: 'CAPTAIN_OPEN_AI_API_KEY').value,
      uri_base: uri_base,
      log_errors: Rails.env.development?
    )
    setup_model
  rescue StandardError => e
    raise "Failed to initialize OpenAI client: #{e.message}"
  end

  private

  # Strips markdown code fences (```json ... ``` or ``` ... ```) that some
  # LLM providers/gateways wrap around JSON responses despite response_format hints.
  def sanitize_json_response(response)
    return response if response.nil?

    response.strip.sub(/\A```(?:\w*)\s*\n?/, '').sub(/\n?\s*```\s*\z/, '').strip
  end

  def openai_credential
    Platform::CredentialManager.fetch_optional(
      account: @account,
      key: Platform::CredentialManager.default_key_for('openai'),
      provider: 'openai',
      purpose: 'ai_provider'
    )
  end

  def uri_base
    endpoint = @credential&.metadata&.dig('api_base').presence || @credential&.metadata&.dig(:api_base).presence
    endpoint ||= InstallationConfig.find_by(name: 'CAPTAIN_OPEN_AI_ENDPOINT')&.value
    endpoint.presence || 'https://api.openai.com/'
  end

  def setup_model
    config_value = @credential&.metadata&.dig('model').presence || @credential&.metadata&.dig(:model).presence
    config_value ||= InstallationConfig.find_by(name: 'CAPTAIN_OPEN_AI_MODEL')&.value
    @model = (config_value.presence || DEFAULT_MODEL)
  end
end
