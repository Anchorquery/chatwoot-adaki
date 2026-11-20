# Lo que el formulario de campañas pregunta a la cuenta de WhatsApp de una
# bandeja (vía Evolution) antes de lanzar:
#
# - #chats: grupos, grupos de avisos de comunidades y canales, con miembros y
#   con si el número de la bandeja puede publicar. En un grupo de avisos, o en
#   cualquier grupo con "solo admins", publicar sin ser admin falla, y el fallo
#   no llega como tal a Chatwoot.
# - #check_numbers: qué números tienen WhatsApp. Escribir a uno que no lo tiene
#   es un 500 seguro y, en frío, lo que antes restringe el número.
#
# Los participantes no salen de aquí: solo se usan para contar y para saber si
# la bandeja es admin.
class Campaigns::WhatsappAudienceService < Evolution::AudienceOptionsService
  MAX_NUMBERS_PER_CHECK = 100

  # Tres llamadas a Evolution de hasta 10 s cada una: en paralelo para no pasar
  # los 15 s de Rack::Timeout (mismo motivo que evolution_audience_options).
  def chats
    owner_thread = Thread.new { owner_number }
    groups_thread = Thread.new { fetch('group/fetchAllGroups', query: { getParticipants: 'true' }) }
    channels_thread = Thread.new { newsletters }
    owner = owner_thread.value

    group_rows = valid_rows(groups_thread.value).reject { |group| group['isCommunity'] }.map { |group| group_row(group, owner) }
    channel_rows = valid_rows(channels_thread.value).map { |channel| channel_row(channel) }
    (group_rows + channel_rows).sort_by { |row| row[:name].to_s.downcase }
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

  def valid_rows(rows)
    Array(rows).select { |row| row.is_a?(Hash) && row['id'].present? }
  end

  def number_rows(rows)
    Array.wrap(rows).select { |row| row.is_a?(Hash) }.map { |row| { number: row['number'].to_s, exists: row['exists'] == true } }
  end

  def group_row(group, owner)
    participants = Array(group['participants']).select { |participant| participant.is_a?(Hash) }
    {
      id: group['id'],
      name: group['subject'].presence || group['id'],
      kind: group['isCommunityAnnounce'] ? 'community' : 'group',
      size: group['size'] || participants.size,
      can_send: can_send?(group, participants, owner)
    }
  end

  def channel_row(channel)
    { id: channel['id'], name: channel['name'].presence || channel['id'], kind: 'channel', size: nil, can_send: nil }
  end

  # nil cuando no se sabe: sin número propio, o si WhatsApp solo da los
  # participantes por @lid y no se puede cruzar con el teléfono.
  def can_send?(group, participants, owner)
    admins_only = group['announce'] == true || group['isCommunityAnnounce'] == true
    return true unless admins_only
    return nil if owner.blank?

    me = participants.find { |participant| participant_numbers(participant).include?(owner) }
    return nil if me.nil?

    %w[admin superadmin].include?(me['admin'].to_s)
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
