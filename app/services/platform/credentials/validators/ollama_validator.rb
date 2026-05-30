module Platform::Credentials::Validators
  class OllamaValidator < Base
    private

    def present_secret?
      @credential.metadata['api_base'].present? || @credential.metadata[:api_base].present?
    end

    def perform_remote_check
      base = (@credential.metadata['api_base'].presence || @credential.metadata[:api_base].presence || 'http://localhost:11434').to_s
      base = base.chomp('/').sub(%r{/v1\z}, '')
      url = "#{base}/api/tags"

      response = HTTParty.get(url, timeout: 10)

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
