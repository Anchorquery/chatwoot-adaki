module Platform::Credentials::Validators
  class Base
    def initialize(credential)
      @credential = credential
    end

    def validate!
      return mark_invalid('missing_secret') unless present_secret?

      if respond_to?(:perform_remote_check, true)
        perform_remote_check
      else
        mark_active
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
        metadata: @credential.metadata.merge('validation' => { 'status' => 'active', 'checked_at' => Time.current.iso8601 })
      )
    end

    def mark_invalid(error_code, message: nil)
      validation = { 'status' => 'invalid', 'error_code' => error_code, 'checked_at' => Time.current.iso8601 }
      validation['message'] = message if message.present?

      @credential.update!(
        status: :invalid_credential,
        last_validated_at: Time.current,
        metadata: @credential.metadata.merge('validation' => validation)
      )
    end
  end
end
