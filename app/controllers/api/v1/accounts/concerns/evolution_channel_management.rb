module Api::V1::Accounts::Concerns::EvolutionChannelManagement
  extend ActiveSupport::Concern

  included do
    # Las acciones del filtro de privacidad no pueden pasar por el
    # check_authorization genérico del controller: ese autoriza la CLASE Inbox,
    # y las políticas de estas dos acciones son por instancia
    # (assigned_inboxes.include?(record)) — con la clase fallan para todo el
    # mundo, admin incluido. Autorizan la instancia dentro de la propia acción.
    skip_before_action :check_authorization, only: [:evolution_privacy_filter, :evolution_update_privacy_filter]
  end

  def evolution_audience_options
    service = Evolution::AudienceOptionsService.new(@inbox)
    render json: { newsletters: service.newsletters, groups: service.groups, contacts: service.contacts }
  end

  def evolution_test_connection
    result = Evolution::AudienceOptionsService.new(@inbox).test_connection
    persist_evolution_verified(result[:success])
    render json: result
  end

  # Estas acciones hablan con Evolution, no con la base de Chatwoot: un fallo
  # ahí NO puede salir como 200. Devolver 200 con {success: false} hacía que el
  # front cantara "guardado" mientras Evolution seguía con la config vieja.
  PRIVACY_FILTER_ERROR_STATUS = {
    'not_configured' => :unprocessable_entity,
    'invalid_mode' => :unprocessable_entity,
    'unreachable' => :bad_gateway,
    'evolution_unreachable' => :bad_gateway,
    'invalid_response' => :bad_gateway
  }.freeze

  # Filtro de privacidad: qué chats de esta bandeja se reenvían a Chatwoot.
  # El estado vive en Evolution (su propia config de la integración con
  # Chatwoot), no en la base de Chatwoot.
  def evolution_privacy_filter
    authorize @inbox, :evolution_privacy_filter?
    result = Evolution::AudienceOptionsService.new(@inbox).current_privacy_filter
    return render json: { error: result[:status] }, status: privacy_filter_error_status(result[:status]) if result[:status] != 'ok'

    render json: result.except(:status)
  end

  def evolution_update_privacy_filter
    authorize @inbox, :evolution_update_privacy_filter?
    result = Evolution::AudienceOptionsService.new(@inbox).update_privacy_filter(
      mode: params[:mode],
      jids: Array(params[:jids])
    )
    return render json: result if result[:success]

    render json: result, status: privacy_filter_error_status(result[:message])
  end

  private

  # Cualquier mensaje no mapeado (ej. "http_401" de Evolution) es un fallo del
  # lado de Evolution, no de la petición del usuario.
  def privacy_filter_error_status(message)
    PRIVACY_FILTER_ERROR_STATUS.fetch(message, :bad_gateway)
  end

  # El frontend nunca recibe la apikey de Evolution, así que tampoco puede
  # reenviarla al guardar. Si llega vacía, se conserva la que ya estaba guardada;
  # solo se reemplaza cuando el admin escribe una nueva.
  def preserve_evolution_api_key(channel_params)
    return channel_params unless channel_params.key?(:additional_attributes)

    incoming = channel_params[:additional_attributes]
    return channel_params if incoming.blank? || incoming['evolution_api_key'].present?

    stored_key = @inbox.channel.additional_attributes.try(:[], 'evolution_api_key')
    return channel_params if stored_key.blank?

    channel_params.merge(additional_attributes: incoming.merge('evolution_api_key' => stored_key))
  end

  # Guardar el resultado del test no debe hacer fallar la respuesta: al usuario le
  # importa saber si Evolution respondió, y perder el flag solo implica volver a
  # probar la conexión.
  def persist_evolution_verified(success)
    @inbox.channel.update!(
      additional_attributes: (@inbox.channel.additional_attributes || {}).merge('evolution_verified' => success)
    )
  rescue StandardError => e
    ChatwootExceptionTracker.new(e).capture_exception
  end
end
