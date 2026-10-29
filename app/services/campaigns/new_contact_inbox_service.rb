# Decide si una campaña puede escribir a un contacto que nunca ha escrito a la
# bandeja y, si puede, lo vincula (o reutiliza el contact_inbox que ya tenga).
#
# Escribir en frío es lo que más rápido restringe un número de WhatsApp, así que
# solo se hace con la opción allow_new_contacts de la campaña y con un tope
# diario de contactos nuevos por bandeja (por número, compartido entre todas sus
# campañas). Al llegar al tope la campaña espera al día siguiente.
#
# Tener contact_inbox no basta: aecfd7da vinculó contactos de listas importadas
# sin que escribieran nunca. Cuenta como conocido quien tiene algún mensaje
# entrante en la bandeja.
class Campaigns::NewContactInboxService
  DEFAULT_DAILY_LIMIT = 20
  NO_CONVERSATION_REASON = 'Contacto sin conversación previa con esta bandeja'.freeze
  NO_PHONE_REASON = 'Contacto sin teléfono'.freeze
  LINK_ERROR_REASON = 'No se pudo vincular el contacto a la bandeja'.freeze

  Result = Struct.new(:contact_inbox, :skip_reason, :limit_reached, keyword_init: true)

  pattr_initialize [:campaign!, :contact!, :contact_inbox]

  def self.daily_limit_for(campaign)
    limit = campaign.delivery_settings.to_h['max_new_contacts_per_day'].to_i
    limit.positive? ? limit : DEFAULT_DAILY_LIMIT
  end

  def self.contact_wrote?(contact_inbox)
    return false if contact_inbox.nil?

    Message.incoming.exists?(conversation_id: contact_inbox.conversations.select(:id))
  end

  def perform
    return Result.new(contact_inbox: contact_inbox) if self.class.contact_wrote?(contact_inbox)
    return skipped(NO_CONVERSATION_REASON) unless allowed?
    return skipped(NO_PHONE_REASON) if contact.phone_number.blank?
    return Result.new(limit_reached: true) unless reserve_slot!

    link!
  end

  private

  def link!
    Result.new(contact_inbox: contact_inbox || ContactInboxBuilder.new(contact: contact, inbox: campaign.inbox).perform)
  rescue StandardError => e
    Rails.logger.warn("[CampaignNewContact] cannot link contact=#{contact.id} inbox=#{campaign.inbox_id}: #{e.message}")
    skipped(LINK_ERROR_REASON)
  end

  def allowed?
    ActiveModel::Type::Boolean.new.cast(campaign.delivery_settings.to_h['allow_new_contacts'])
  end

  def skipped(reason)
    Result.new(skip_reason: reason)
  end

  # incr y comparar en un solo paso: con get + incr, dos campañas de la misma
  # bandeja podían pasar el tope a la vez. Si el vínculo falla después, ese
  # hueco se pierde hasta el día siguiente.
  def reserve_slot!
    count = Redis::Alfred.incr(counter_key)
    Redis::Alfred.expire(counter_key, 2.days.to_i) if count == 1
    count <= self.class.daily_limit_for(campaign)
  end

  def counter_key
    "campaigns:new_contacts:inbox:#{campaign.inbox_id}:#{local_today}"
  end

  def local_today
    (ActiveSupport::TimeZone[campaign.inbox.timezone] || Time.zone).today.iso8601
  end
end
