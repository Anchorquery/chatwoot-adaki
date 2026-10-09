require 'rails_helper'

RSpec.describe Captain::Conversation::ClarificationGate do
  subject(:gate) { described_class.new(conversation: conversation, assistant: assistant) }

  let(:account) { create(:account, locale: 'es') }
  let(:inbox) { create(:inbox, account: account) }
  let(:assistant) { create(:captain_assistant, account: account) }
  let(:conversation) { create(:conversation, inbox: inbox, account: account, status: :pending) }

  def incoming(content, **attrs)
    create(:message, conversation: conversation, account: account, inbox: inbox, message_type: :incoming, content: content, **attrs)
  end

  describe '#applies?' do
    it 'gates the canned WhatsApp web-button opener' do
      incoming('Hola, quiero más información sobre sus productos.')

      expect(gate.applies?).to be(true)
      expect(gate.word_count).to eq(7)
    end

    it 'gates an English generic opener' do
      incoming('Hi! I would like more information about your services please')

      expect(gate.applies?).to be(true)
    end

    it 'gates a Portuguese generic opener' do
      incoming('Olá, gostaria de mais informações sobre os produtos')

      expect(gate.applies?).to be(true)
    end

    it 'gates a burst of short generic messages as one text' do
      incoming('Hola buenas')
      incoming('quiero información')

      expect(gate.applies?).to be(true)
    end

    it 'survives emoji and punctuation' do
      incoming('Hola!!! 👋 quiero info, por favor...')

      expect(gate.applies?).to be(true)
    end

    it 'does not gate a message that names a product (unknown token)' do
      incoming('Hola, quiero información sobre el pack premium')

      expect(gate.applies?).to be(false)
    end

    it 'does not gate a typo (conservative allow-list)' do
      incoming('Hola quiero informacón')

      expect(gate.applies?).to be(false)
    end

    it 'does not gate a real question' do
      incoming('Hola, cuánto cuesta el envío a Canarias?')

      expect(gate.applies?).to be(false)
    end

    it 'does not gate a single-word opener (keeps the usual path, like the scenario pre-route)' do
      incoming('Hola')

      expect(gate.applies?).to be(false)
    end

    it 'does not gate more than MAX_WORDS words' do
      incoming((['hola'] * (described_class::MAX_WORDS + 1)).join(' '))

      expect(gate.applies?).to be(false)
    end

    it 'does not gate text with digits' do
      incoming('Hola quiero información del pedido 4521')

      expect(gate.applies?).to be(false)
    end

    it 'does not gate text with a URL' do
      incoming('Hola quiero información sobre https://example.com/producto')

      expect(gate.applies?).to be(false)
    end

    it 'does not gate a message carrying an attachment' do
      message = incoming('Hola quiero información')
      message.attachments.create!(account: account, file_type: :image, external_url: 'https://example.com/foto.jpg')

      expect(gate.applies?).to be(false)
    end

    it 'does not gate once any public outgoing message exists (not the first bot turn)' do
      create(:message, conversation: conversation, account: account, inbox: inbox, message_type: :outgoing, sender: assistant,
                       content: 'Hola, ¿en qué puedo ayudarte?')
      incoming('Hola quiero más información')

      expect(gate.applies?).to be(false)
    end

    it 'ignores a private note when deciding whether it is the first bot turn' do
      agent = create(:user, account: account)
      create(:message, conversation: conversation, account: account, inbox: inbox, message_type: :outgoing, sender: agent,
                       private: true, content: 'nota interna')
      incoming('Hola quiero más información')

      expect(gate.applies?).to be(true)
    end

    it 'does not gate a campaign conversation (its outreach message is already outgoing)' do
      create(:message, conversation: conversation, account: account, inbox: inbox, message_type: :outgoing, content: 'Campaign text')
      incoming('Hola quiero más información')

      expect(gate.applies?).to be(false)
    end

    it 'asks only once: the marker blocks a second generic burst' do
      incoming('Hola quiero más información')
      gate.mark_asked!

      expect(described_class.new(conversation: conversation.reload, assistant: assistant).applies?).to be(false)
    end

    it 'does not gate when the assistant disabled it' do
      assistant.update!(config: assistant.config.merge('clarification_gate_enabled' => false))
      incoming('Hola quiero más información')

      expect(gate.applies?).to be(false)
    end

    it 'treats a string "false" from the API as disabled' do
      assistant.update!(config: assistant.config.merge('clarification_gate_enabled' => 'false'))
      incoming('Hola quiero más información')

      expect(gate.applies?).to be(false)
    end

    it 'does not gate an empty conversation' do
      expect(gate.applies?).to be(false)
    end
  end

  describe '#reply_text' do
    it 'uses the assistant message when configured' do
      assistant.update!(config: assistant.config.merge('clarification_message' => '¿Qué producto te interesa?'))

      expect(gate.reply_text).to eq('¿Qué producto te interesa?')
    end

    it 'falls back to the i18n prompt in the account locale' do
      expect(gate.reply_text).to eq(I18n.t('conversations.captain.clarification_prompt', locale: :es))
      expect(gate.reply_text).not_to eq(I18n.t('conversations.captain.clarification_prompt', locale: :en))
    end

    it 'falls back to i18n when the configured message is blank' do
      assistant.update!(config: assistant.config.merge('clarification_message' => '   '))

      expect(gate.reply_text).to eq(I18n.t('conversations.captain.clarification_prompt', locale: :es))
    end
  end

  describe '#mark_asked!' do
    it 'stamps captain_clarification_asked_at without touching other attributes' do
      conversation.update!(additional_attributes: { 'browser' => 'x' })

      gate.mark_asked!

      attrs = conversation.reload.additional_attributes
      expect(attrs['browser']).to eq('x')
      expect(Time.zone.parse(attrs[described_class::MARKER_KEY])).to be_within(5.seconds).of(Time.current)
    end
  end
end
