module Platform::Credentials::Validators
  class BedrockValidator < Base
    private

    def present_secret?
      super && (@credential.secret(:secret_key).present? || @credential.secret(:region).present?)
    end
  end
end
