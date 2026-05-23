class Api::V1::Accounts::Adaki::AuditLogEntriesController < Api::V1::Accounts::BaseController
  before_action :check_admin_authorization?

  def index
    entries = Adaki::AuditLogEntry.for_account(Current.account).order(recorded_at: :desc)
    entries = entries.where(action: params[:action_filter]) if params[:action_filter].present?
    entries = entries.where(auditable_type: params[:auditable_type]) if params[:auditable_type].present?
    entries = entries.where(auditable_id: params[:auditable_id]) if params[:auditable_id].present?
    render json: entries.limit(500)
  end

  def verify
    Adaki::AuditLogEntry.verify_chain!(Current.account)
    render json: { valid: true }
  rescue StandardError => e
    render json: { valid: false, error: e.message }, status: :unprocessable_entity
  end
end
