module Platform::Credentials::Validators
  class Base
    def initialize(credential)
      @credential = credential
    end

    def validate!
      if present_secret?
        mark_active
      else
        mark_invalid('missing_secret')
      end
      @credential
    end

    private

    def present_secret?
      case @credential.auth_type
      when 'api_key'
        @credential.secret(:api_key).present?
      when 'bearer'
        @credential.secret(:token).present?
      when 'basic'
        @credential.secret(:username).present? && @credential.secret(:password).present?
      when 'oauth2'
        @credential.secret(:access_token).present? || @credential.secret(:refresh_token).present?
      else
        @credential.payload.present?
      end
    end

    def mark_active
      @credential.update!(
        status: :active,
        last_validated_at: Time.current,
        metadata: @credential.metadata.merge('validation' => { 'status' => 'active' })
      )
    end

    def mark_invalid(error_code)
      @credential.update!(
        status: :invalid_credential,
        last_validated_at: Time.current,
        metadata: @credential.metadata.merge('validation' => { 'status' => 'invalid', 'error_code' => error_code })
      )
    end
  end
end
