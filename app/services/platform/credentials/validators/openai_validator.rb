module Platform::Credentials::Validators
  class OpenaiValidator < Base
    private

    def perform_remote_check
      api_key = @credential.secret(:api_key)
      return mark_invalid('missing_secret') if api_key.blank?

      base = @credential.metadata['api_base'].presence || 'https://api.openai.com/v1'
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
  end
end
