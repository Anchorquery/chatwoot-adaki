class Platform::Credentials::Validators::BedrockValidator < Platform::Credentials::Validators::Base
  private

  def present_secret?
    super && (@credential.secret(:secret_key).present? || @credential.secret(:region).present?)
  end
end
