module Platform::Credentials::Validators
  class OllamaValidator < Base
    private

    def present_secret?
      @credential.metadata['api_base'].present? || @credential.metadata[:api_base].present?
    end
  end
end
