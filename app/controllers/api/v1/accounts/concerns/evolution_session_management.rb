# Sesión de WhatsApp (instancia de Evolution) de una bandeja, gestionada desde
# Chatwoot: crearla, ver si está conectada, mostrar el QR y desconectarla, sin
# pasar por el Manager de Evolution.
module Api::V1::Accounts::Concerns::EvolutionSessionManagement
  extend ActiveSupport::Concern

  CREATE_ERROR_STATUS = {
    'not_configured' => :unprocessable_entity,
    'name_required' => :unprocessable_entity,
    'name_taken' => :unprocessable_entity
  }.freeze

  CONNECTION_ERROR_STATUS = {
    'not_configured' => :unprocessable_entity
  }.freeze

  included do
    skip_before_action :fetch_inbox, only: [:evolution_create]
    before_action :validate_limit, only: [:evolution_create]
    # destroy vive en el controller que incluye este concern.
    before_action :release_evolution_instance, only: [:destroy] # rubocop:disable Rails/LexicallyScopedActionFilter
  end

  # Crea la instancia en Evolution y su bandeja en un solo paso. El QR se pide
  # después con evolution_connect.
  def evolution_create
    @inbox = Evolution::InstanceService.new(account: Current.account, user: Current.user).create_inbox(name: params[:name])
    render 'api/v1/accounts/inboxes/create', status: :created
  rescue Evolution::InstanceService::Error => e
    render json: { error: e.code }, status: CREATE_ERROR_STATUS.fetch(e.code, :bad_gateway)
  end

  def evolution_connection_state
    render_evolution_connection(evolution_connection_service.connection_state)
  end

  def evolution_connect
    render_evolution_connection(evolution_connection_service.connect)
  end

  def evolution_logout
    render_evolution_result(evolution_connection_service.logout)
  end

  def evolution_restart
    render_evolution_result(evolution_connection_service.restart)
  end

  def evolution_instance_settings
    render_evolution_connection(evolution_connection_service.instance_settings)
  end

  def evolution_update_instance_settings
    changes = params.permit(:reject_call, :msg_call, :groups_ignore, :newsletter_ignore, :always_online, :read_messages, :read_status)
    render_evolution_result(evolution_connection_service.update_instance_settings(changes))
  end

  private

  def evolution_connection_service
    Evolution::ConnectionService.new(@inbox)
  end

  # Fallos de Evolution (caído, 401, respuesta rara) salen como 502: no son
  # culpa de la petición del usuario.
  def render_evolution_connection(result)
    return render json: result.except(:status) if result[:status] == 'ok'

    render json: { error: result[:status] }, status: CONNECTION_ERROR_STATUS.fetch(result[:status], :bad_gateway)
  end

  def render_evolution_result(result)
    return render json: result if result[:success]

    render json: result, status: CONNECTION_ERROR_STATUS.fetch(result[:message], :bad_gateway)
  end

  # Al borrar una bandeja cuya instancia creó Chatwoot, la instancia se borra
  # también en Evolution: si no, se queda huérfana reintentando la conexión.
  # Best effort: un Evolution caído no puede impedir el borrado.
  def release_evolution_instance
    return unless @inbox&.api?
    return unless @inbox.channel.additional_attributes.try(:[], 'evolution_managed_instance')

    evolution_connection_service.delete_instance
  rescue StandardError => e
    ChatwootExceptionTracker.new(e).capture_exception
  end
end
