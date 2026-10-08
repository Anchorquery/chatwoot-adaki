# Directorio de chats para el filtro de privacidad de una bandeja Evolution:
# buscar a quién bloquear (o permitir) y ponerle nombre a lo ya seleccionado.
#
# Mezcla dos fuentes:
# - Evolution: todos los chats del número, también los que el filtro oculta y
#   que por tanto nunca llegaron a Chatwoot. Solo para quien puede ver las
#   audiencias completas (include_evolution); a un agente le expondría chats
#   que el filtro le esconde a propósito.
# - Chatwoot: los contactos que ya escribieron a esta bandeja. Rápido, sin
#   depender de que Evolution responda, y visible para cualquiera con acceso.
class Evolution::PrivacyDirectoryService
  include Evolution::PrivacySupport

  PAGE_SIZE = 30
  TYPES = %w[contact group channel].freeze

  def initialize(inbox:, include_evolution:)
    @inbox = inbox
    @include_evolution = include_evolution
  end

  def search(query:, type:, page:)
    type = TYPES.include?(type) ? type : 'contact'
    query = query.to_s.strip.first(100)
    page = [page.to_i, 1].max

    evolution_items, evolution_more = @include_evolution ? evolution_search(query, type, page) : [[], false]
    chatwoot_items, chatwoot_more = chatwoot_search(query, type, page)

    { items: merge_items(evolution_items + chatwoot_items), has_more: evolution_more || chatwoot_more }
  end

  # Nombres de lo ya seleccionado: ver Evolution::PrivacyLabelsService.
  def resolve(jids)
    labels_service.resolve(jids)
  end

  def remember_labels(labels, jids)
    labels_service.remember(labels, jids)
  end

  private

  def labels_service
    @labels_service ||= Evolution::PrivacyLabelsService.new(inbox: @inbox, include_evolution: @include_evolution)
  end

  # --- Evolution --------------------------------------------------------------

  def evolution_search(query, type, page)
    return evolution_contact_search(query, page) if type == 'contact'

    list = type == 'group' ? cached_groups : cached_channels
    items = list.filter_map { |item| type == 'group' ? group_item(item) : channel_item(item) }
    items = items.select { |item| matches?(item, query) } if query.present?
    paginate(items, page)
  end

  # Dos fuentes a la vez, porque ninguna basta sola:
  # - la agenda (findContacts) trae a quien nunca escribió;
  # - los chats (findChats) traen a quien escribió sin estar agendado.
  # Van en paralelo: cada llamada puede tardar hasta el timeout de Evolution y
  # en serie se sumarían. Los chats (actividad reciente) van primero y los
  # duplicados se unen en merge_items.
  #
  # Un Evolution sin la búsqueda parcial ignora `search` y devolvería la agenda
  # sin filtrar: se reconoce porque no trae remoteJidAlt y se descarta.
  def evolution_contact_search(query, page)
    service = audience_service
    contacts_thread = Thread.new { service.search_contacts(query: query, take: PAGE_SIZE, page: page) }
    chats_thread = Thread.new { service.search_chats(query: query, take: PAGE_SIZE, skip: (page - 1) * PAGE_SIZE) }
    contacts = contacts_thread.value
    chats = chats_thread.value
    contacts = [] if contacts.any? && contacts.none? { |row| row.key?('remoteJidAlt') }

    items = (chats + contacts).filter_map { |row| chat_item(row) }
    [items, chats.size >= PAGE_SIZE || contacts.size >= PAGE_SIZE]
  end

  def chat_item(row)
    jid = row['remoteJid'].to_s
    return nil if jid.blank? || jid.end_with?('@g.us', '@newsletter') || jid == 'status@broadcast'

    # En un chat "@lid" se guarda el teléfono equivalente: el filtro de
    # Evolution lo compara contra remoteJidAlt, y es lo que el admin reconoce.
    alt = row['remoteJidAlt'].to_s
    selected = alt.end_with?('@s.whatsapp.net') ? alt : jid
    build_item(selected, row['pushName'], 'contact', row['profilePicUrl'], 'whatsapp')
  end

  def group_item(group)
    return nil if group['id'].blank?

    build_item(group['id'], group['subject'], 'group', group['pictureUrl'], 'whatsapp')
  end

  def channel_item(channel)
    return nil if channel['id'].blank?

    build_item(channel['id'], channel['name'] || channel.dig('thread_metadata', 'name', 'text'), 'channel', channel['picture'], 'whatsapp')
  end

  # --- Chatwoot ---------------------------------------------------------------

  def chatwoot_search(query, type, page)
    scope = inbox_contacts.where(type_condition(type))
    scope = scope.where(search_condition(query), **search_values(query)) if query.present?
    rows = scope.order(Arel.sql('contacts.last_activity_at DESC NULLS LAST'), 'contacts.id')
                .offset((page - 1) * PAGE_SIZE).limit(PAGE_SIZE + 1)
                .pluck('contacts.identifier', 'contacts.phone_number', 'contacts.name')

    items = rows.first(PAGE_SIZE).filter_map { |identifier, phone, name| contact_item(identifier, phone, name, type) }
    [items, rows.size > PAGE_SIZE]
  end

  def type_condition(type)
    case type
    when 'group' then "contacts.identifier LIKE '%@g.us'"
    when 'channel' then "contacts.identifier LIKE '%@newsletter'"
    else "(contacts.identifier IS NULL OR (contacts.identifier NOT LIKE '%@g.us' AND contacts.identifier NOT LIKE '%@newsletter'))"
    end
  end

  # "+34 600 11" debe encontrar "+34600111222": además del texto tal cual, se
  # busca por los dígitos sueltos contra teléfono e identificador.
  def search_condition(query)
    conditions = ['contacts.name ILIKE :text', 'contacts.phone_number ILIKE :text', 'contacts.identifier ILIKE :text']
    conditions += ['contacts.phone_number ILIKE :digits', 'contacts.identifier ILIKE :digits'] if digits(query).length >= 4
    "(#{conditions.join(' OR ')})"
  end

  def search_values(query)
    {
      text: "%#{ActiveRecord::Base.sanitize_sql_like(query)}%",
      digits: "%#{digits(query)}%"
    }
  end

  def contact_item(identifier, phone, name, type)
    jid = jid_for(identifier, phone, type)
    return nil if jid.blank?

    build_item(jid, name, type, nil, 'chatwoot')
  end

  def jid_for(identifier, phone, type)
    return identifier if identifier.to_s.include?('@')
    return nil unless type == 'contact'

    number = digits(phone)
    number.present? ? "#{number}@s.whatsapp.net" : nil
  end

  # --- Comunes ----------------------------------------------------------------

  def build_item(jid, name, type, picture, source)
    phone = phone_for(jid)
    {
      jid: jid,
      name: name.to_s.strip.presence || (phone ? "+#{phone}" : jid),
      phone: phone,
      type: type,
      picture_url: picture.to_s.start_with?('https://') ? picture : nil,
      source: source
    }
  end

  # Evolution trae nombre y foto más frescos: gana sobre el duplicado de
  # Chatwoot, conservando el orden en que llegaron.
  def merge_items(items)
    items.each_with_object({}) do |item, merged|
      merged[item[:jid]] ||= item
    end.values
  end

  def matches?(item, query)
    text = query.downcase
    item[:name].to_s.downcase.include?(text) || item[:jid].include?(text) ||
      (digits(query).length >= 4 && item[:jid].include?(digits(query)))
  end

  def paginate(items, page)
    start = (page - 1) * PAGE_SIZE
    [items[start, PAGE_SIZE] || [], items.size > start + PAGE_SIZE]
  end
end
