# Ayudas del formulario de campañas antes de lanzar: chats de WhatsApp de la
# bandeja, comprobación de números y resumen de a quién llegaría.
module Api::V1::Accounts::Concerns::CampaignAudienceActions
  AUDIENCE_ACTIONS = %i[whatsapp_chats whatsapp_chat_permissions check_numbers audience_preview].freeze

  def whatsapp_chats
    render json: Campaigns::WhatsappAudienceService.new(audience_inbox).chats(query: params[:q], kind: params[:kind], page: params[:page])
  end

  def whatsapp_chat_permissions
    render json: { permissions: Campaigns::WhatsappAudienceService.new(audience_inbox).chat_permissions(params[:jids]) }
  end

  def check_numbers
    numbers = Array(params[:numbers]).map(&:to_s)
    result = Campaigns::WhatsappAudienceService.new(audience_inbox).check_numbers(numbers)
    return render json: { error: result[:status] }, status: :bad_gateway unless result[:status] == 'ok'

    render json: { results: result[:results] }
  end

  def audience_preview
    render json: Campaigns::AudiencePreviewService.new(
      account: Current.account,
      inbox: audience_inbox,
      audience: Array(params[:audience]).map { |entry| entry.permit(:type, :id, :name).to_h },
      delivery_settings: params[:delivery_settings].respond_to?(:permit) ? params[:delivery_settings].permit!.to_h : {}
    ).perform
  end

  private

  def audience_inbox
    @audience_inbox ||= Current.account.inboxes.find(params[:inbox_id])
  end
end
