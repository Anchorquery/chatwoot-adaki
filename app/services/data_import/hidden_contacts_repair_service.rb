# Recupera los contactos que importaciones CSV antiguas crearon solo con el
# nombre. Con encabezados como "Correo electrónico", "teléfono" o "label", el
# email, el teléfono y las etiquetas acabaron en atributos personalizados y,
# sin email ni teléfono, la lista de contactos no los muestra (ver
# Contact.resolved_contacts).
#
# Cada contacto oculto se repara pasando esos datos a su sitio; si la misma
# persona ya existe con ese teléfono (por ejemplo, porque luego se importó un
# archivo corregido), el oculto sobra y se borra, salvo que tenga
# conversaciones. Con dry_run solo cuenta lo que haría.
class DataImport::HiddenContactsRepairService
  PHONE_FORMAT = /\A\+[1-9]\d{1,14}\z/
  IMPORTED_COLUMNS = %w[email phone_number labels].freeze

  def initialize(account:, dry_run: true)
    @account = account
    @dry_run = dry_run
    @claimed_phones = Set.new
    @claimed_emails = Set.new
  end

  def perform
    hidden_contacts.find_each.with_object(Hash.new(0)) do |contact, result|
      result[repair(contact)] += 1
    end
  end

  private

  attr_reader :account

  def hidden_contacts
    account.contacts.where(email: [nil, ''], phone_number: [nil, ''], identifier: [nil, '']).where.not(custom_attributes: {})
  end

  # Los datos se buscan en todas las columnas importadas, no solo en la suya:
  # en filas descolocadas el teléfono quedó bajo "Correo electrónico" y la
  # etiqueta bajo "teléfono". Si no aparece ni teléfono ni email, el contacto no
  # se toca.
  def repair(contact)
    values = imported_values(contact.custom_attributes)
    phone = phone_in(values)
    email = email_in(values)
    return :unrecoverable if phone.blank? && email.blank?
    return remove_duplicate(contact) if duplicate?(contact, phone, email)

    restore(contact, values, phone, email)
  end

  # Las claves de custom_attributes son los encabezados del CSV original.
  def imported_values(custom_attributes)
    custom_attributes.filter_map do |header, value|
      value.to_s.strip.presence if imported_header?(header)
    end
  end

  def phone_in(values)
    values.filter_map { |value| normalized_phone(value) }.first
  end

  def email_in(values)
    values.map(&:downcase).find { |value| value.match?(Devise.email_regexp) && value.include?('.') }
  end

  def normalized_phone(value)
    digits = value.delete(' ').delete_prefix('+')
    return unless digits.match?(/\A\d{8,15}\z/)

    phone = "+#{digits}"
    phone if phone.match?(PHONE_FORMAT)
  end

  # El teléfono identifica a la persona; el email solo cuando no hay teléfono,
  # porque una familia puede compartir correo.
  def duplicate?(contact, phone, email)
    others = account.contacts.where.not(id: contact.id)
    return @claimed_phones.include?(phone) || others.exists?(phone_number: phone) if phone

    @claimed_emails.include?(email) || others.from_email(email).present?
  end

  def remove_duplicate(contact)
    return :kept_with_conversations if contact.conversations.exists?

    contact.destroy! unless @dry_run
    :removed_duplicate
  end

  def restore(contact, values, phone, email)
    contact.phone_number = phone if phone
    contact.email = email if email_free?(contact, email)
    contact.custom_attributes = contact.custom_attributes.reject { |header, value| value.blank? || imported_header?(header) }
    contact.label_list.add(existing_labels(values))
    return :invalid unless contact.valid?

    save_restored(contact)
  end

  def save_restored(contact)
    contact.save! unless @dry_run
    @claimed_phones << contact.phone_number if contact.phone_number.present?
    @claimed_emails << contact.email if contact.email.present?
    :restored
  end

  def email_free?(contact, email)
    return false if email.blank? || @claimed_emails.include?(email)

    account.contacts.where.not(id: contact.id).from_email(email).blank?
  end

  def imported_header?(header)
    IMPORTED_COLUMNS.include?(DataImport::CsvRows.normalize_header(header))
  end

  def existing_labels(values)
    names = values.flat_map { |value| value.split(',') }.map { |name| name.strip.downcase }.compact_blank
    account.labels.where('LOWER(title) IN (?)', names).pluck(:title)
  end
end
