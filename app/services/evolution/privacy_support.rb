# Piezas compartidas por los servicios del filtro de privacidad de una bandeja
# Evolution (directorio de búsqueda y nombres). Requiere @inbox.
module Evolution::PrivacySupport
  LABELS_KEY = 'evolution_privacy_labels'.freeze
  # Los nombres recordados viven en additional_attributes del canal: con un
  # tope, para que una lista enorme no infle esa columna sin límite.
  MAX_LABELS = 3000
  LIST_CACHE_TTL = 10.minutes
  # fetchAllGroups puede tardar decenas de segundos (ver
  # AudienceOptionsService#groups). Las rutas que leen esta lista se saltan
  # Rack::Timeout (config/initializers/rack_timeout.rb) para poder esperarla.
  GROUPS_READ_TIMEOUT = 45
  # Mientras una petición pide la lista, las demás la esperan en vez de lanzar
  # otra igual contra Evolution.
  LIST_LOADING_TTL = 50.seconds

  private

  def audience_service
    @audience_service ||= Evolution::AudienceOptionsService.new(@inbox)
  end

  # Grupos y canales del número, cacheados unos minutos: fetchAllGroups es de
  # las llamadas más caras de Evolution. Un fallo devuelve [] y no se cachea:
  # si no, la lista se quedaría vacía aunque Evolution vuelva enseguida.
  def list_cache_key(kind)
    "evolution:privacy:#{@inbox.id}:#{kind}"
  end

  def cached_list(kind, &)
    key = list_cache_key(kind)
    cached = Rails.cache.read(key)
    return cached if cached

    loading_key = "#{key}:loading"
    return wait_for_list(key, loading_key) unless Rails.cache.write(loading_key, true, unless_exist: true, expires_in: LIST_LOADING_TTL)

    begin
      load_list(key, &)
    ensure
      Rails.cache.delete(loading_key)
    end
  end

  def load_list(key)
    fresh = Array.wrap(yield).select { |item| item.is_a?(Hash) }
    Rails.cache.write(key, fresh, expires_in: LIST_CACHE_TTL) if fresh.any?
    fresh
  end

  # Si la otra petición falla no deja nada en caché: se devuelve [] en cuanto
  # suelta el aviso de carga, sin volver a pedirla.
  def wait_for_list(key, loading_key)
    deadline = LIST_LOADING_TTL.from_now
    while Time.current < deadline
      sleep 1
      cached = Rails.cache.read(key)
      return cached if cached
      return [] unless Rails.cache.exist?(loading_key)
    end
    []
  end

  def cached_groups
    cached_list(:groups) { audience_service.groups(read_timeout: GROUPS_READ_TIMEOUT) }
  end

  def cached_channels
    cached_list(:channels) { audience_service.newsletters }
  end

  # Subconsulta y no JOIN + DISTINCT: Postgres no deja ordenar un DISTINCT por
  # una columna (last_activity_at) que no está en el SELECT.
  def inbox_contacts
    Contact.where(account_id: @inbox.account_id)
           .where(id: ContactInbox.where(inbox_id: @inbox.id).select(:contact_id))
  end

  # Solo los JIDs de persona tienen teléfono: un "@lid" son dígitos opacos y un
  # número pelado ("34600…", como lo guarda el Manager) sí es un teléfono.
  def phone_for(jid)
    jid = jid.to_s
    return jid.split('@').first if jid.end_with?('@s.whatsapp.net')
    return jid if jid.match?(/\A\d{6,}\z/)

    nil
  end

  def digits(value)
    value.to_s.gsub(/\D/, '')
  end

  def stored_labels
    labels = @inbox.channel.additional_attributes.try(:[], LABELS_KEY)
    labels.is_a?(Hash) ? labels : {}
  end

  def write_labels(labels)
    channel = @inbox.channel
    channel.update!(additional_attributes: (channel.additional_attributes || {}).merge(LABELS_KEY => labels.first(MAX_LABELS).to_h))
  end
end
