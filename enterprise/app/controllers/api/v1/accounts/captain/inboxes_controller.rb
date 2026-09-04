class Api::V1::Accounts::Captain::InboxesController < Api::V1::Accounts::BaseController
  before_action :current_account
  before_action -> { check_authorization(Captain::Assistant) }

  before_action :set_assistant
  def index
    @captain_inboxes = @assistant.captain_inboxes.includes(:inbox)
  end

  def create
    inbox = Current.account.inboxes.find(assistant_params[:inbox_id])
    @captain_inbox = @assistant.captain_inboxes.build(inbox: inbox)
    @captain_inbox.save!
  end

  def update
    @captain_inbox = @assistant.captain_inboxes.find_by!(inbox_id: permitted_params[:inbox_id])
    # The UI sends the complete override set. Replacing it is required for
    # "inherit": deleting a key must remove the persisted override instead of
    # being resurrected by a merge with the old JSON object.
    @captain_inbox.update!(settings: settings_params.to_h.stringify_keys)
    render json: { settings: @captain_inbox.settings }
  end

  def destroy
    @captain_inbox = @assistant.captain_inboxes.find_by!(inbox_id: permitted_params[:inbox_id])
    @captain_inbox.destroy!
    head :no_content
  end

  private

  def settings_params
    params.require(:captain_inbox).permit(
      settings: [:auto_handoff_enabled, :auto_resolve_hours, :continue_after_human_takeover,
                 :human_takeover_mode, :human_takeover_window_minutes, :handoff_team_id]
    )[:settings] || {}
  end

  def set_assistant
    @assistant = account_assistants.find(permitted_params[:assistant_id])
  end

  def account_assistants
    @account_assistants ||= Current.account.captain_assistants
  end

  def permitted_params
    params.permit(:assistant_id, :id, :account_id, :inbox_id)
  end

  def assistant_params
    params.require(:inbox).permit(:inbox_id)
  end
end
