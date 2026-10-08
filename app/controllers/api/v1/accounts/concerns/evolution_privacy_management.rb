# Filtro de privacidad de una bandeja Evolution: buscar chats para añadir,
# poner nombre a los ya elegidos y el atajo por contacto desde la conversación.
#
# Igual que el resto del filtro, la autorización es por instancia (bandejas
# asignadas o permiso de gestión), no por la clase Inbox.
module Api::V1::Accounts::Concerns::EvolutionPrivacyManagement
  extend ActiveSupport::Concern

  PRIVACY_ACTIONS = %i[evolution_privacy_search evolution_privacy_resolve evolution_privacy_contact evolution_update_privacy_contact].freeze

  PRIVACY_CONTACT_ERROR_STATUS = {
    'not_configured' => :unprocessable_entity,
    'no_jid' => :unprocessable_entity,
    'last_allowed' => :unprocessable_entity
  }.freeze

  included do
    skip_before_action :check_authorization, only: PRIVACY_ACTIONS
  end

  def evolution_privacy_search
    authorize @inbox, :evolution_privacy_filter?
    render json: privacy_directory.search(query: params[:q], type: params[:type], page: params[:page])
  end

  def evolution_privacy_resolve
    authorize @inbox, :evolution_privacy_filter?
    render json: { labels: privacy_directory.resolve(params[:jids]) }
  end

  def evolution_privacy_contact
    authorize @inbox, :evolution_privacy_filter?
    result = contact_privacy_service.status
    return render json: result.except(:status).merge(jids: contact_privacy_service.contact_jids) if result[:status] == 'ok'

    render json: { error: result[:status] }, status: PRIVACY_CONTACT_ERROR_STATUS.fetch(result[:status], :bad_gateway)
  end

  def evolution_update_privacy_contact
    authorize @inbox, :evolution_update_privacy_filter?
    result = contact_privacy_service.update(filtered: ActiveModel::Type::Boolean.new.cast(params[:filtered]) == true)
    return render json: result if result[:success]

    render json: result, status: PRIVACY_CONTACT_ERROR_STATUS.fetch(result[:message], :bad_gateway)
  end

  private

  # Las listas completas de Evolution solo para quien ya puede ver las
  # audiencias: a un agente le expondrían chats que el filtro le oculta.
  def privacy_directory
    @privacy_directory ||= Evolution::PrivacyDirectoryService.new(
      inbox: @inbox,
      include_evolution: policy(@inbox).evolution_audience_options?
    )
  end

  # Solo contactos que escribieron a ESTA bandeja: el id viene del cliente.
  def contact_privacy_service
    @contact_privacy_service ||= begin
      contact = @inbox.contact_inboxes.find_by!(contact_id: params[:contact_id]).contact
      Evolution::ContactPrivacyService.new(@inbox, contact)
    end
  end

  # Best effort: el filtro ya se guardó en Evolution; perder los nombres solo
  # significa ver números en la lista hasta el próximo guardado.
  def remember_privacy_labels(jids)
    return if params[:labels].blank?

    privacy_directory.remember_labels(params[:labels].permit!.to_h, jids)
  rescue StandardError => e
    ChatwootExceptionTracker.new(e).capture_exception
  end
end
