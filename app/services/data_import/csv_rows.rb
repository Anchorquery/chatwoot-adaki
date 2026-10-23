# Limpieza de las filas del CSV de contactos antes de construir cada contacto.
class DataImport::CsvRows
  # Encabezados que la gente escribe en sus hojas (castellano, euskera) para las
  # columnas que entiende el importador. Sin esto, "Correo electrónico" o
  # "teléfono" acababan como atributos personalizados y el contacto se creaba
  # solo con el nombre: sin email, sin teléfono y sin etiquetas.
  HEADER_ALIASES = {
    'name' => %w[nombre izena],
    'email' => ['e-mail', 'mail', 'correo', 'correo electronico', 'correo electrónico', 'emaila', 'posta elektronikoa'],
    'phone_number' => %w[phone telefono teléfono movil móvil celular whatsapp telefonoa mugikorra],
    'labels' => %w[label etiqueta etiquetas etiketa etiketak]
  }.flat_map { |header, aliases| aliases.map { |name| [name, header] } }.to_h.freeze

  def self.normalize_header(header)
    name = header.to_s.strip
    HEADER_ALIASES.fetch(name.downcase, name)
  end

  def initialize
    @phones_by_email = {}
  end

  # Columnas sin encabezado (una coma final) y celdas vacías no aportan nada:
  # antes terminaban como atributos personalizados vacíos.
  def clean(row)
    row_hash = row.to_h.reject { |header, value| header.blank? || value.blank? }.with_indifferent_access
    drop_repeated_email(row_hash)
    row_hash
  end

  private

  # Dos filas del archivo con el mismo email y distinto teléfono son dos personas
  # (una familia que comparte correo). Como el email es único por cuenta, la
  # segunda se descartaba en silencio al insertar; ahora entra sin email. Con el
  # mismo teléfono es la misma persona repetida y se sigue fusionando.
  def drop_repeated_email(row_hash)
    email = row_hash[:email].to_s.downcase
    return if email.blank?

    phone = row_hash[:phone_number].to_s.delete_prefix('+')
    seen_phone = @phones_by_email.fetch(email) { return @phones_by_email[email] = phone }
    row_hash.delete(:email) if phone.present? && phone != seen_phone
  end
end
