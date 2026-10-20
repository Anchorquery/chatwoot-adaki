# Los usuarios que ya tenían un rol con channel_operate no eran colaboradores
# de los números de WhatsApp de su cuenta, así que no los veían ni recibían sus
# mensajes. Desde ahora se les añade al asignar el rol; esto pone al día a los
# que ya lo tenían.
class GrantWhatsappInboxesToChannelOperators < ActiveRecord::Migration[7.1]
  def up
    return unless defined?(CustomRoles::WhatsappInboxAccessService)

    AccountUser.where.not(custom_role_id: nil).includes(:custom_role).find_each do |account_user|
      CustomRoles::WhatsappInboxAccessService.grant_for_account_user(account_user)
    end
  end

  def down
    # No se distingue a quién se añadió aquí de quién se añadió a mano.
  end
end
