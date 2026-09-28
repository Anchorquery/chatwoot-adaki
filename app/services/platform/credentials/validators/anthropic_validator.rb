class Platform::Credentials::Validators::AnthropicValidator < Platform::Credentials::Validators::Base
  private

  def perform_remote_check
    api_key = @credential.secret(:api_key)
    return mark_invalid('missing_secret') if api_key.blank?

    base = @credential.metadata['api_base'].presence || 'https://api.anthropic.com'
    url = "#{base.chomp('/')}/v1/models"

    response = HTTParty.get(
      url,
      headers: { 'x-api-key' => api_key, 'anthropic-version' => '2023-06-01' },
      timeout: 10
    )

    if response.success?
      mark_active
    else
      mark_invalid("http_#{response.code}", message: response.body.to_s[0, 200])
    end
  rescue StandardError => e
    mark_invalid('network_error', message: e.message)
  end
end
