# Las importaciones CSV con encabezados como "Correo electrónico" o "teléfono"
# creaban cada contacto solo con el nombre: el email y el teléfono quedaban en
# atributos personalizados y la lista de contactos no los muestra. Se borran
# esos contactos fantasma para poder importar de nuevo el archivo corregido.
#
# Solo se borra un contacto que cumpla todo: creado mientras se procesaba una
# importación de contactos de su cuenta, sin email, teléfono ni identificador,
# con el email o el teléfono guardado bajo un encabezado importado y sin ninguna
# conversación.
class DeleteHiddenImportedContacts < ActiveRecord::Migration[7.1]
  IMPORTED_DETAIL_COLUMNS = %w[email phone_number].freeze

  def up
    deleted = 0
    DataImport.where(data_type: 'contacts').find_each do |data_import|
      ghost_candidates(data_import).find_each do |contact|
        next unless imported_details?(contact.custom_attributes)

        contact.destroy!
        deleted += 1
      end
    end
    say "Contactos fantasma borrados: #{deleted}"
  end

  def down
    # Borrados: no se pueden recuperar.
  end

  private

  def ghost_candidates(data_import)
    Contact.where(account_id: data_import.account_id, email: [nil, ''], phone_number: [nil, ''], identifier: [nil, ''])
           .where(created_at: data_import.created_at..(data_import.updated_at + 1.minute))
           .where.not(custom_attributes: {})
           .where.not(id: Conversation.select(:contact_id))
  end

  def imported_details?(custom_attributes)
    custom_attributes.any? do |header, value|
      value.present? && IMPORTED_DETAIL_COLUMNS.include?(DataImport::CsvRows.normalize_header(header))
    end
  end
end
