class Api::V1::Accounts::Adaki::AbsencesController < Api::V1::Accounts::BaseController
  before_action :fetch_absence, only: [:show, :update, :destroy]
  before_action -> { check_authorization(Adaki::Absence) }

  def index
    @absences = Adaki::Absence.where(account_id: Current.account.id).order(start_at: :desc)
    render json: @absences
  end

  def show
    render json: @absence
  end

  def create
    @absence = Adaki::Absence.create!(absence_params.merge(account_id: Current.account.id))
    Adaki::AuditLogger.log(
      account: Current.account,
      user: Current.user,
      action: 'absence.created',
      auditable: @absence,
      payload: absence_params.to_h
    )
    render json: @absence, status: :created
  end

  def update
    @absence.update!(update_params)
    Adaki::AuditLogger.log(
      account: Current.account,
      user: Current.user,
      action: 'absence.updated',
      auditable: @absence,
      payload: update_params.to_h
    )
    render json: @absence
  end

  def destroy
    @absence.update!(status: 'cancelled')
    Adaki::AuditLogger.log(
      account: Current.account,
      user: Current.user,
      action: 'absence.cancelled',
      auditable: @absence,
      payload: {}
    )
    head :no_content
  end

  private

  def fetch_absence
    @absence = Adaki::Absence.where(account_id: Current.account.id).find(params[:id])
  end

  def absence_params
    params.require(:absence).permit(:user_id, :coverage_user_id, :start_at, :end_at, :reason, :status, metadata: {})
  end

  # user_id is immutable post-creation to keep audit trail unambiguous.
  def update_params
    params.require(:absence).permit(:coverage_user_id, :start_at, :end_at, :reason, :status, metadata: {})
  end
end
