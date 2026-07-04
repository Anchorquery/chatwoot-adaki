class Api::V1::Accounts::Adaki::CaptainSettingsController < Api::V1::Accounts::BaseController
  before_action :check_admin_authorization?

  def show
    render json: serialize_settings
  end

  def update
    # params.require rejects blank values too (not just a missing key), so an
    # intentional '' (clear the limit) would 422 before reaching .presence
    # below. fetch only enforces that the key is present.
    limit = params.fetch(:adaki_captain_monthly_limit)
    Current.account.update!(adaki_captain_monthly_limit: limit.presence&.to_i)

    Adaki::AuditLogger.log(
      account: Current.account,
      user: Current.user,
      action: 'captain.limit.updated',
      payload: { limit: limit }
    )

    render json: serialize_settings
  end

  private

  def serialize_settings
    usage = Adaki::CaptainUsage.current_for(Current.account)
    {
      adaki_captain_monthly_limit: Current.account.adaki_captain_monthly_limit,
      current_period: usage.period,
      request_count: usage.request_count,
      input_tokens: usage.input_tokens,
      output_tokens: usage.output_tokens,
      providers: Llm::Models.providers,
      credentials: Current.account.platform_credentials.order(created_at: :desc).map do |credential|
        {
          id: credential.id,
          name: credential.name,
          key: credential.key,
          provider: credential.provider,
          purpose: credential.purpose,
          auth_type: credential.auth_type,
          status: credential.status,
          token_hint: credential.token_hint,
          metadata: credential.metadata,
          last_used_at: credential.last_used_at,
          last_validated_at: credential.last_validated_at,
          expires_at: credential.expires_at
        }
      end
    }
  end
end
