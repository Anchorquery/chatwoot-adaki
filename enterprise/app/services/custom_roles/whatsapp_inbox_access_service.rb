# Quien tiene un rol personalizado con `channel_operate` trabaja con los
# números de WhatsApp de la cuenta: se le hace colaborador de todas sus
# bandejas. Ser colaborador es lo que da todo lo demás (ver el número en
# Conexiones de WhatsApp, recibir sus conversaciones en tiempo real y poder
# usarla en campañas), así que no hace falta añadirlo a mano bandeja a bandeja.
#
# Solo añade: quitar el permiso no saca a nadie de una bandeja, porque no se
# distingue un colaborador añadido aquí de uno puesto a mano.
class CustomRoles::WhatsappInboxAccessService
  PERMISSION = 'channel_operate'.freeze
  # Evolution arma el webhook de la bandeja como ".../chatwoot/webhook/{instancia}".
  EVOLUTION_WEBHOOK_PATH = '/chatwoot/webhook/'.freeze

  def self.whatsapp_inbox?(inbox)
    inbox.whatsapp? || (inbox.api? && inbox.channel.try(:webhook_url).to_s.include?(EVOLUTION_WEBHOOK_PATH))
  end

  # Un usuario: todas las bandejas de WhatsApp de su cuenta.
  def self.grant_for_account_user(account_user)
    return unless operator?(account_user)

    inboxes = account_user.account.inboxes.includes(:channel).select { |inbox| whatsapp_inbox?(inbox) }
    inboxes.each { |inbox| add_member(inbox, account_user.user_id) }
  end

  # Una bandeja nueva: todos los operadores de su cuenta.
  def self.grant_for_inbox(inbox)
    return unless whatsapp_inbox?(inbox)

    inbox.account.account_users.where.not(custom_role_id: nil).includes(:custom_role).find_each do |account_user|
      add_member(inbox, account_user.user_id) if operator?(account_user)
    end
  end

  def self.operator?(account_user)
    account_user.custom_role.present? && account_user.permissions.include?(PERMISSION)
  end

  def self.add_member(inbox, user_id)
    inbox.inbox_members.find_or_create_by!(user_id: user_id)
  rescue ActiveRecord::RecordNotUnique
    nil
  end
  private_class_method :operator?, :add_member
end
