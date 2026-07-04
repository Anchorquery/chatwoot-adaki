module Platform::Credentials::Validators
  # Generic OpenAI-compatible validator for providers that expose /v1/models
  # via Bearer auth (DeepSeek, Mistral, Groq, OpenRouter, Perplexity, Custom).
  class GenericHttpValidator < Base
    private

    def perform_remote_check
      api_key = @credential.secret(:api_key) || @credential.secret(:token)
      return mark_invalid('missing_secret') if api_key.blank?

      base = @credential.metadata['api_base'].presence
      base ||= provider_default_base
      return mark_invalid('missing_api_base') if base.blank?

      url = "#{base.chomp('/')}/models"
      response = HTTParty.get(url, headers: { 'Authorization' => "Bearer #{api_key}" }, timeout: 10)

      if response.success?
        mark_active
      else
        mark_invalid("http_#{response.code}", message: response.body.to_s[0, 200])
      end
    rescue StandardError => e
      mark_invalid('network_error', message: e.message)
    end

    def provider_default_base
      {
        'deepseek' => 'https://api.deepseek.com/v1',
        'mistral' => 'https://api.mistral.ai/v1',
        'groq' => 'https://api.groq.com/openai/v1',
        'openrouter' => 'https://openrouter.ai/api/v1',
        'perplexity' => 'https://api.perplexity.ai'
      }[@credential.provider]
    end
  end
end
