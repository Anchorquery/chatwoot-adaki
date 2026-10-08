# Nombres de los chats de un filtro de privacidad: los chats excluidos nunca
# llegan a Chatwoot, así que sin esto la lista se vería como números sueltos.
#
# Orden de búsqueda, de lo más barato a lo más caro: nombres ya guardados,
# contactos de Chatwoot y, para lo que falte, Evolution (agenda por lotes y
# listas de grupos/canales). Lo que aporta Evolution se guarda, así que cada
# filtro antiguo solo paga ese coste la primera vez que se abre.
class Evolution::PrivacyLabelsService
  include Evolution::PrivacySupport

  def initialize(inbox:, include_evolution:)
    @inbox = inbox
    @include_evolution = include_evolution
  end

  # { jid => { name:, phone: } }
  def resolve(jids)
    jids = Array(jids).map(&:to_s).reject(&:blank?).uniq.first(MAX_LABELS)
    labels = stored_labels.slice(*jids)
    missing = jids - labels.keys
    labels.merge!(chatwoot_labels(missing)) if missing.any?

    missing = jids - labels.keys
    labels.merge!(backfill_from_evolution(missing)) if @include_evolution && missing.any?

    jids.index_with { |jid| { name: labels[jid].presence, phone: phone_for(jid) } }
  end

  # Al guardar el filtro: el nombre que el admin vio al elegir cada JID. Se
  # poda a la lista guardada para no arrastrar nombres de chats ya quitados.
  def remember(labels, jids)
    keep = Array(jids).map(&:to_s)
    incoming = labels.to_h.stringify_keys.slice(*keep).transform_values { |name| name.to_s.strip.first(120) }.compact_blank
    write_labels(stored_labels.slice(*keep).merge(incoming))
  end

  private

  # Completa sin borrar nada y no rompe la lectura si el guardado falla.
  def backfill_from_evolution(jids)
    found = evolution_labels(jids)
    write_labels(stored_labels.merge(found)) if found.any?
    found
  rescue StandardError => e
    ChatwootExceptionTracker.new(e).capture_exception
    found || {}
  end

  def evolution_labels(jids)
    groups, others = jids.partition { |jid| jid.end_with?('@g.us') }
    channels, contacts = others.partition { |jid| jid.end_with?('@newsletter') }

    labels = {}
    labels.merge!(contact_labels(contacts)) if contacts.any?
    labels.merge!(list_labels(groups, cached_groups, 'subject')) if groups.any?
    labels.merge!(list_labels(channels, cached_channels, 'name')) if channels.any?
    labels
  end

  # Una sola llamada para todos los contactos. Un contacto guardado como
  # "@lid" vuelve con su teléfono en remoteJidAlt: casa por cualquiera de los dos.
  def contact_labels(jids)
    wanted = jids.to_set
    audience_service.contacts_by_jids(jids).each_with_object({}) do |row, labels|
      name = row['pushName'].to_s.strip
      next if name.blank?

      [row['remoteJid'], row['remoteJidAlt']].each { |key| labels[key] ||= name if wanted.include?(key) }
    end
  end

  def list_labels(jids, list, name_key)
    wanted = jids.to_set
    list.each_with_object({}) do |item, labels|
      name = item[name_key].to_s.strip
      labels[item['id']] = name if wanted.include?(item['id']) && name.present?
    end
  end

  def chatwoot_labels(jids)
    wanted = jids.to_set
    phones = jids.filter_map { |jid| phone_for(jid) }.map { |phone| "+#{phone}" }
    rows = inbox_contacts.where('contacts.identifier IN (:jids) OR contacts.phone_number IN (:phones)', jids: jids, phones: phones)
                         .where.not(name: [nil, ''])
                         .pluck('contacts.identifier', 'contacts.phone_number', 'contacts.name')

    rows.each_with_object({}) do |(identifier, phone, name), labels|
      label_keys(identifier, phone).each { |key| labels[key] ||= name if wanted.include?(key) }
    end
  end

  # Un mismo contacto puede estar guardado en el filtro como JID completo, como
  # JID de teléfono o como número pelado: se prueban las tres formas.
  def label_keys(identifier, phone)
    number = digits(phone)
    [identifier, ("#{number}@s.whatsapp.net" if number.present?), number.presence].compact
  end
end
