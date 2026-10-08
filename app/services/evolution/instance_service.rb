# Crea instancias de WhatsApp (Baileys) en Evolution API desde Chatwoot, ya
# enlazadas a una bandeja API de esta cuenta, para no tener que pasar por el
# Manager de Evolution.
#
# Usa la apikey GLOBAL de Evolution (EVOLUTION_API_KEY), que solo vive en el
# servidor (Super Admin > Evolution API o variable de entorno). A la bandeja se
# le guarda el token propio de la instancia que devuelve Evolution, que solo
# controla esa instancia.
class Evolution::InstanceService
  include Evolution::HttpClient

  class Error < StandardError
    attr_reader :code

    def initialize(code, message = code)
      @code = code
      super(message)
    end
  end

  def self.configured?
    GlobalConfigService.load('EVOLUTION_API_URL', '').present? && GlobalConfigService.load('EVOLUTION_API_KEY', '').present?
  end

  def initialize(account:, user:)
    @account = account
    @user = user
  end

  # Crea la instancia en Evolution y luego la bandeja. Si la bandeja falla, se
  # borra la instancia: una instancia huérfana se queda reintentando conectar.
  def create_inbox(name:)
    raise Error, 'not_configured' unless self.class.configured?

    name = name.to_s.strip
    raise Error, 'name_required' if name.blank?
    # Evolution busca la bandeja de Chatwoot POR NOMBRE (getInbox en su
    # chatwoot.service.ts): con dos bandejas homónimas en la cuenta, los
    # mensajes de una podrían acabar en la otra.
    raise Error, 'name_taken' if @account.inboxes.exists?(name: name)

    instance_name = build_instance_name(name)
    created = create_instance(instance_name, name)

    begin
      build_inbox(name, instance_name, created)
    rescue StandardError
      delete_instance(instance_name)
      raise
    end
  end

  private

  def create_instance(instance_name, inbox_name)
    payload = create_payload(instance_name, inbox_name)
    response = evolution_request("#{base_url}/instance/create", api_key: global_api_key, method: :post, body: payload)
    raise Error, 'unreachable' if response.nil?
    raise Error.new('evolution_rejected', "Evolution respondió #{response.code}") unless response.is_a?(Net::HTTPSuccess)

    data = parse_json(response)
    raise Error, 'invalid_response' unless data.is_a?(Hash) && data['hash'].present?

    data
  end

  def create_payload(instance_name, inbox_name)
    {
      instanceName: instance_name,
      integration: 'WHATSAPP-BAILEYS',
      qrcode: true,
      chatwootAccountId: @account.id.to_s,
      chatwootToken: @user.access_token.token,
      chatwootUrl: chatwoot_url,
      chatwootNameInbox: inbox_name,
      # La bandeja la crea Chatwoot (abajo), no Evolution: así no aparece el
      # contacto de servicio de Evolution ni su conversación de avisos.
      chatwootAutoCreate: false,
      chatwootSignMsg: false,
      chatwootReopenConversation: true,
      chatwootConversationPending: false,
      chatwootImportContacts: false,
      chatwootImportMessages: false
    }
  end

  def build_inbox(name, instance_name, created)
    ActiveRecord::Base.transaction do
      channel = @account.api_channels.create!(
        webhook_url: webhook_url_for(instance_name, created),
        additional_attributes: {
          'evolution_api_key' => created['hash'],
          'evolution_verified' => true,
          # Marca las instancias que Chatwoot creó (y por tanto puede borrar
          # al borrar la bandeja). Las vinculadas a mano no la llevan.
          'evolution_managed_instance' => true
        }
      )
      @account.inboxes.create!(name: name, channel: channel)
    end
  end

  # Evolution informa la URL de webhook que espera (armada con su SERVER_URL):
  # es la misma que pone cuando crea la bandeja él mismo desde el Manager.
  def webhook_url_for(instance_name, created)
    created.dig('chatwoot', 'webhookUrl').presence ||
      "#{base_url}/chatwoot/webhook/#{ERB::Util.url_encode(instance_name)}"
  end

  def delete_instance(instance_name)
    evolution_request("#{base_url}/instance/delete/#{ERB::Util.url_encode(instance_name)}", api_key: global_api_key, method: :delete)
  end

  # Nombre único y legible en Evolution: el nombre de la bandeja sin acentos ni
  # espacios, más un sufijo para que dos cuentas puedan usar el mismo nombre.
  def build_instance_name(name)
    slug = name.parameterize.first(40).presence || 'whatsapp'
    "#{slug}-#{SecureRandom.hex(3)}"
  end

  def base_url
    GlobalConfigService.load('EVOLUTION_API_URL', '').to_s.chomp('/')
  end

  def global_api_key
    GlobalConfigService.load('EVOLUTION_API_KEY', '')
  end

  # URL con la que Evolution llama a Chatwoot. Por defecto la pública; se
  # puede apuntar a una interna si ambos viven en la misma red.
  def chatwoot_url
    GlobalConfigService.load('EVOLUTION_CHATWOOT_URL', '').presence || ENV.fetch('FRONTEND_URL', '')
  end
end
