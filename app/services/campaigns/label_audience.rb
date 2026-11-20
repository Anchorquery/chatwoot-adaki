# Contactos de una campaña que salen de etiquetas: las del contacto y las de
# sus conversaciones. Lo usan el planificador (envío real) y el resumen previo.
#
# ExcludeLabel quita a quien tenga esa etiqueta, venga de donde venga (una
# etiqueta, un número suelto o un grupo): es la lista de "no escribir".
module Campaigns::LabelAudience
  INCLUDE_TYPE = 'Label'.freeze
  EXCLUDE_TYPE = 'ExcludeLabel'.freeze

  module_function

  def contact_ids(account, audience, type: INCLUDE_TYPE)
    label_ids = Array(audience).map { |entry| entry.to_h.stringify_keys }.select { |entry| entry['type'] == type }.pluck('id')
    titles = account.labels.where(id: label_ids).pluck(:title)
    return [] if titles.empty?

    directly_tagged_ids = account.contacts.tagged_with(titles, any: true).pluck(:id)
    via_conversation_ids = account.conversations.tagged_with(titles, any: true).pluck(:contact_id).compact
    (directly_tagged_ids + via_conversation_ids).uniq
  end

  def excluded_contact_ids(account, audience)
    contact_ids(account, audience, type: EXCLUDE_TYPE)
  end
end
