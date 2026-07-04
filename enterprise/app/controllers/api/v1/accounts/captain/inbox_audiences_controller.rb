class Api::V1::Accounts::Captain::InboxAudiencesController < Api::V1::Accounts::BaseController
  before_action :current_account
  before_action -> { check_authorization(Captain::Assistant) }

  before_action :set_assistant
  before_action :set_audience, only: [:update, :destroy]

  def index
    @audiences = @assistant.captain_inbox_audiences.includes(:inbox)
  end

  def create
    inbox = Current.account.inboxes.find(audience_params[:inbox_id])
    @audience = @assistant.captain_inbox_audiences.build(
      inbox: inbox,
      group_jids: audience_params[:group_jids] || [],
      label_titles: audience_params[:label_titles] || []
    )
    @audience.save!
  end

  def update
    @audience.update!(audience_params.except(:inbox_id).to_h)
    render json: { id: @audience.id, group_jids: @audience.group_jids, label_titles: @audience.label_titles }
  end

  def destroy
    @audience.destroy!
    head :no_content
  end

  private

  def set_assistant
    @assistant = account_assistants.find(permitted_params[:assistant_id])
  end

  def set_audience
    @audience = @assistant.captain_inbox_audiences.find(permitted_params[:id])
  end

  def account_assistants
    @account_assistants ||= Current.account.captain_assistants
  end

  def permitted_params
    params.permit(:assistant_id, :id, :account_id)
  end

  def audience_params
    params.require(:captain_inbox_audience).permit(:inbox_id, group_jids: [], label_titles: [])
  end
end
