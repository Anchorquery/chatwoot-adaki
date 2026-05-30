module Platform::Credentials::Validators
  class AzureOpenaiValidator < Base
    private

    def perform_remote_check
      api_key = @credential.secret(:api_key)
      return mark_invalid('missing_secret') if api_key.blank?

      base = @credential.metadata['api_base'].presence
      return mark_invalid('missing_api_base') if base.blank?

      api_version = @credential.metadata['api_version'].presence || '2024-02-15-preview'
      url = "#{base.chomp('/')}/openai/deployments?api-version=#{api_version}"

      response = HTTParty.get(url, headers: { 'api-key' => api_key }, timeout: 10)

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
