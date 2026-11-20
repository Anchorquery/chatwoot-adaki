# Lo que el formulario de campañas pregunta a la cuenta de WhatsApp de una
# bandeja (vía Evolution) antes de lanzar:
#
# - #chats: buscador paginado de grupos, grupos de avisos de comunidades y
#   canales. Sale de la misma lista cacheada que el filtro de privacidad (la
#   ligera, sin participantes): pedir los participantes de todos los grupos
#   hacía que un número con muchos grupos superara el timeout y solo quedaran
#   los canales.
# - #chat_permissions: si el número de la bandeja puede publicar en los grupos
#   elegidos. En un grupo de avisos, o en cualquier grupo con "solo admins",
#   publicar sin ser admin falla, y el fallo no llega como tal a Chatwoot. Se
#   mira grupo a grupo y solo para lo elegido.
# - #check_numbers: qué números tienen WhatsApp. Escribir a uno que no lo tiene
#   es un 500 seguro y, en frío, lo que antes restringe el número.
#
# Los participantes no salen de aquí: solo se usan para saber si la bandeja es
# admin.
class Campaigns::WhatsappAudienceService < Evolution::AudienceOptionsService
  include Evolution::PrivacySupport

  MAX_NUMBERS_PER_CHECK = 100
  PAGE_SIZE = 30
  KINDS = %w[group community channel].freeze
  MAX_PERMISSION_CHECKS = 20
  # Cada comprobación es una llamada a Evolution de hasta 5 s: de diez en diez
  # para no pasar los 15 s de Rack::Timeout.
  PERMISSION_BATCH = 10

  def chats(query: nil, kind: nil, page: 1)
    groups, channels = chat_lists
    rows = filter_rows(groups.map { |group| group_row(group) } + channels.map { |channel| channel_row(channel) }, query, kind)
    start = ([page.to_i, 1].max - 1) * PAGE_SIZE
    { chats: rows[start, PAGE_SIZE] || [], has_more: rows.size > start + PAGE_SIZE, total: rows.size,
      groups_unavailable: groups.empty? }
  end

  # { jid => true | false | nil }; nil cuando no se sabe (Evolution no
  # responde, sin número propio, o participantes solo por @lid).
  def chat_permissions(jids)
    jids = Array(jids).map(&:to_s).select { |jid| jid.end_with?('@g.us') }.uniq.first(MAX_PERMISSION_CHECKS)
    return {} if jids.empty?

    # Solo lo que ya esté en caché: esta ruta no se salta Rack::Timeout y no
    # puede esperar a la lista entera. Lo que no esté se comprueba con los
    # participantes.
    known = Array(Rails.cache.read(list_cache_key(:groups))).index_by { |group| group['id'] }
    open_jids, admin_jids = jids.partition { |jid| known[jid] && !admins_only?(known[jid]) }
    open_jids.index_with(true).merge(admin_permissions(admin_jids))
  end

  def check_numbers(numbers)
    numbers = Array(numbers).map(&:to_s).compact_blank.uniq.first(MAX_NUMBERS_PER_CHECK)
    return { status: 'not_configured' } unless configured?
    return { status: 'ok', results: [] } if numbers.empty?

    response = request("#{base_url}/chat/whatsappNumbers/#{encoded_instance_name}", method: :post, body: { numbers: numbers })
    return { status: 'unreachable' } unless response.is_a?(Net::HTTPSuccess)

    { status: 'ok', results: number_rows(JSON.parse(response.body)) }
  rescue JSON::ParserError
    { status: 'invalid_response' }
  end

  private

  # PrivacySupport habla con Evolution a través de este servicio.
  def audience_service
    self
  end

  # En paralelo: la lista de grupos puede tardar mucho la primera vez y la de
  # canales no tiene por qué esperarla.
  def chat_lists
    groups_thread = Thread.new { cached_groups }
    channels = valid_rows(cached_channels)
    groups = valid_rows(groups_thread.value).reject { |group| group['isCommunity'] }
    [groups, channels]
  end

  def filter_rows(rows, query, kind)
    rows = rows.select { |row| row[:kind] == kind } if KINDS.include?(kind)
    query = query.to_s.strip.first(100)
    rows = rows.select { |row| matches?(row, query) } if query.present?
    rows.sort_by { |row| normalize(row[:name]) }
  end

  def admin_permissions(jids)
    return {} if jids.empty?

    owner_thread = Thread.new { owner_number }
    participants = jids.each_slice(PERMISSION_BATCH).with_object({}) do |batch, result|
      batch.map { |jid| [jid, Thread.new { group_participants(jid) }] }.each { |jid, thread| result[jid] = thread.value }
    end
    owner = owner_thread.value
    jids.index_with { |jid| admin?(participants[jid], owner) }
  end

  def group_participants(jid)
    response = fetch('group/participants', query: { groupJid: jid }).first
    return unless response.is_a?(Hash) && response['participants'].is_a?(Array)

    response['participants'].select { |participant| participant.is_a?(Hash) }
  end

  def admin?(participants, owner)
    return nil if participants.nil? || owner.blank?

    me = participants.find { |participant| participant_numbers(participant).include?(owner) }
    return nil if me.nil?

    %w[admin superadmin].include?(me['admin'].to_s)
  end

  def valid_rows(rows)
    Array(rows).select { |row| row.is_a?(Hash) && row['id'].present? }
  end

  def number_rows(rows)
    Array.wrap(rows).select { |row| row.is_a?(Hash) }.map { |row| { number: row['number'].to_s, exists: row['exists'] == true } }
  end

  # can_send nil en los de "solo admins": se comprueba con #chat_permissions
  # cuando se eligen.
  def group_row(group)
    admins_only = admins_only?(group)
    {
      id: group['id'],
      name: group['subject'].presence || group['id'],
      kind: group['isCommunityAnnounce'] ? 'community' : 'group',
      size: group['size'],
      admins_only: admins_only,
      can_send: admins_only ? nil : true
    }
  end

  def channel_row(channel)
    { id: channel['id'], name: channel['name'].presence || channel['id'], kind: 'channel', size: nil, admins_only: false,
      can_send: nil }
  end

  def admins_only?(group)
    group['announce'] == true || group['isCommunityAnnounce'] == true
  end

  # Sin distinguir mayúsculas ni acentos: "vecinos" encuentra "Vecinos Peñón".
  def matches?(row, query)
    text = normalize(query)
    normalize(row[:name]).include?(text) || row[:id].to_s.include?(text)
  end

  def normalize(text)
    I18n.transliterate(text.to_s.unicode_normalize(:nfkc)).downcase
  end

  def participant_numbers(participant)
    [participant['id'], participant['phoneNumber'], participant['jid']].filter_map do |value|
      value = value.to_s
      value.split('@').first.split(':').first if value.end_with?('@s.whatsapp.net')
    end
  end

  def owner_number
    response = request("#{base_url}/instance/fetchInstances", query: { instanceName: instance_name })
    return unless response.is_a?(Net::HTTPSuccess)

    instance = Array.wrap(JSON.parse(response.body)).find { |item| item.is_a?(Hash) }
    instance && instance['ownerJid'].to_s.split('@').first.split(':').first.presence
  rescue JSON::ParserError
    nil
  end
end
