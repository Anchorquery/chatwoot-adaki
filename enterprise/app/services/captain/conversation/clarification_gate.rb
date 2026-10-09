# Deterministic gate for the very first Captain turn of a conversation.
#
# A WhatsApp button on a website opens the chat with a canned opener such as
# "Hola, quiero más información sobre sus productos". That text names no
# product and no topic, yet the LLM turn still pays a prefetch and a
# `faq_lookup` with an empty-ish query, the search always returns something
# (see Captain::Tools::FaqLookupTool) and the assistant answers with product
# links instead of asking what the customer wants. Prompt-only fixes lose
# against the tool result and are neither deterministic across providers nor
# unit-testable; a full LLM turn (8-11 s) for a message that does not need
# one is also the wrong default.
#
# The gate fires only when ALL of these hold, and otherwise stays out of the
# way so the normal V1/V2 path runs exactly as before:
#   * enabled on the assistant (`clarification_gate_enabled`, default true);
#   * first bot turn: no public outgoing message in the conversation at all
#     (a campaign conversation already has one, so it is never gated) and
#     no `captain_clarification_asked_at` marker — the gate asks once;
#   * the customer burst (every public incoming message so far, since there
#     is no outgoing yet) has between MIN_WORDS and MAX_WORDS words, no
#     digits, no URL and no attachment;
#   * after normalising (downcase, transliterate, strip punctuation/emoji)
#     EVERY token belongs to the generic es/en/pt vocabulary below. One
#     unknown token — a product name, a brand, a typo — means the message is
#     specific enough for the LLM. The allow-list is the false-positive
#     guard: it can only ever gate text made entirely of greetings,
#     courtesy, "I want info/prices/products" and connectors.
class Captain::Conversation::ClarificationGate
  AGENT_NAME = 'clarification_gate'.freeze
  MARKER_KEY = 'captain_clarification_asked_at'.freeze
  REASON = 'generic_info_request'.freeze

  # A single word ("hola", "info") keeps today's path, like
  # Captain::Conversation::ScenarioRouter::MIN_QUERY_WORDS: nothing to gate on.
  MIN_WORDS = 2
  MAX_WORDS = 12

  URL_PATTERN = %r{https?://|www\.|\w\.(?:com|net|org|es|pt|br|io|app|me)\b}i

  # Inline on purpose: the allow-list IS the behaviour and is reviewed with the code.
  # rubocop:disable Metrics/CollectionLiteralLength
  GENERIC_VOCABULARY = %w[
    hola buenas buenos dias dia tardes tarde noches noche saludos hello hi hey oi ola bom boa
    que tal como estas esta estan estais usted ustedes vos vosotros voces
    por favor gracias please thanks thank you obrigado obrigada disculpa disculpe disculpen
    perdon perdona perdone desculpa desculpe amable amables atentamente cordial cordiales
    estimado estimada estimados senor senora sr sra sres dear team equipo
    quiero quisiera queria querria necesito necesitaria necesitamos queremos quisieramos
    me nos gustaria interesa interesaria interesado interesada interesados interesadas
    deseo deseamos busco buscamos quero gostaria gostariamos preciso precisamos
    desejo desejamos interesse interessado interessada interessados interessadas
    want wants wanted would like need needs looking for interested
    saber conocer tener obtener recibir pedir solicitar solicito consultar consulta pregunta preguntar duda dudas
    informar informarme informarnos cotizar presupuestar
    know get have receive ask request asking question questions doubt enquiry inquiry
    ter obter receber conhecer
    informacion info informaciones information informacao informacoes
    detalle detalles detail details datos data
    precio precios price prices pricing preco precos tarifa tarifas costo costos coste costes cost costs valor valores
    producto productos product products produto produtos
    servicio servicios service services servico servicos
    catalogo catalogos catalog catalogue catalogues oferta ofertas offer offers
    promocion promociones promo promos promocao promocoes
    cotizacion cotizaciones presupuesto presupuestos quote quotes orcamento orcamentos
    ayuda ayudar help ajuda ajudar
    podrian podria pueden puede puedo podemos can could pode podem poderia posso
    dar darme darnos give enviar envia envien enviarme enviarnos send mandar mandarme mandarnos
    pasar pasarme pasarnos compartir share
    tienen tiene tengan hay existe existen is are there has
    vi visto he hemos saw seen vimos
    web pagina website site sitio anuncio anuncios ad ads publicidad contacto contact
    whatsapp instagram facebook google tiktok mensaje mensajes message messages numero number
    de del la el los las un una unos unas y o a en con sobre para mas lo su sus tu tus mi mis
    i we my the an and or about of on in to more some this that these those your our its it
    do da dos das os as no na nas ao aos um uma e ou com mais seu sua seus suas
    esto eso este estos isso isto acerca respecto aqui alli ahi aca here
    si yes sim ok okay vale bueno bien good great fine
  ].to_set.freeze
  # rubocop:enable Metrics/CollectionLiteralLength

  def initialize(conversation:, assistant:)
    @conversation = conversation
    @assistant = assistant
  end

  # true when this turn should get the clarification prompt instead of an
  # LLM reply. Cheap: a couple of indexed queries and string work, no LLM.
  def applies?
    return false unless @assistant.clarification_gate_enabled?
    return false unless first_bot_turn?

    messages = burst_messages
    return false if messages.empty? || messages.any? { |message| message.attachments.exists? }

    generic_text?(messages.map { |message| message.content.to_s }.join(' '))
  end

  # Number of words the gate looked at (for the log line). nil until
  # #applies? tokenized something.
  attr_reader :word_count

  def reply_text
    configured = @assistant.config['clarification_message']
    return configured if configured.present?

    I18n.with_locale(@assistant.account.locale) { I18n.t('conversations.captain.clarification_prompt') }
  end

  # Stamped so the gate asks at most once per conversation, even if the
  # customer's next message is just as generic.
  def mark_asked!
    @conversation.update!(
      additional_attributes: (@conversation.additional_attributes || {}).merge(MARKER_KEY => Time.current.iso8601)
    )
  end

  private

  def first_bot_turn?
    return false if @conversation.additional_attributes&.dig(MARKER_KEY).present?

    @conversation.messages.outgoing.where(private: false).none?
  end

  # Every public incoming message so far: with no outgoing message yet, the
  # whole conversation is the customer's opening burst (the job already
  # debounced it into one run).
  def burst_messages
    @conversation.messages.incoming.where(private: false).order(:created_at).to_a
  end

  def generic_text?(text)
    return false if text.match?(/\d/) || text.match?(URL_PATTERN)

    tokens = tokenize(text)
    @word_count = tokens.size
    return false unless tokens.size.between?(MIN_WORDS, MAX_WORDS)

    tokens.all? { |token| GENERIC_VOCABULARY.include?(token) }
  end

  def tokenize(text)
    I18n.transliterate(text.downcase)
        .gsub(/[^a-z\s]/, ' ')
        .split
  end
end
