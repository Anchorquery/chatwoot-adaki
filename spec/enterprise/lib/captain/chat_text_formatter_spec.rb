require 'rails_helper'

RSpec.describe Captain::ChatTextFormatter do
  describe '.chat_channel?' do
    it 'is true for WhatsApp bridges, WhatsApp Cloud API and SMS' do
      expect(described_class.chat_channel?('Channel::Api')).to be(true)
      expect(described_class.chat_channel?('Channel::Whatsapp')).to be(true)
      expect(described_class.chat_channel?('Channel::Sms')).to be(true)
      expect(described_class.chat_channel?('Channel::TwilioSms')).to be(true)
    end

    it 'is false for channels that render Markdown themselves' do
      expect(described_class.chat_channel?('Channel::WebWidget')).to be(false)
      expect(described_class.chat_channel?('Channel::Email')).to be(false)
      expect(described_class.chat_channel?('Channel::Telegram')).to be(false)
      expect(described_class.chat_channel?(nil)).to be(false)
    end
  end

  describe '.format' do
    it 'returns the text untouched for non-chat channels' do
      text = "### Title\n[link](https://example.com)"

      expect(described_class.format(text, channel_type: 'Channel::WebWidget')).to eq(text)
    end

    it 'returns blank input as-is' do
      expect(described_class.format('', channel_type: 'Channel::Api')).to eq('')
      expect(described_class.format(nil, channel_type: 'Channel::Api')).to eq('')
    end

    context 'with a Channel::Api inbox (Evolution bridge)' do
      subject(:format) { described_class.format(text, channel_type: 'Channel::Api') }

      context 'when the reply uses the catalogue layout seen in production' do
        let(:text) do
          <<~MD
            Aquí tienes nuestro catálogo detallado:

            ### Tarjetas NFC
            Ideales para llevar contigo:
            * **1 Tarjeta NFC:** 18,90 €
            * **Pack 3 Tarjetas NFC:** 37,90 €

            ### Soportes NFC (Expositores para mostrador)
            * **Soporte NFC para Google Reviews:** 22,90 €

            Puedes ver todos los detalles en nuestra web:
            [https://www.puntuaminegocio.com/productos/](https://www.puntuaminegocio.com/productos/)

            ¿Te interesa algún producto en particular?
          MD
        end

        it 'turns headings into bold lines' do
          expect(format).to include("**Tarjetas NFC**\nIdeales para llevar contigo:")
          expect(format).to include('**Soportes NFC (Expositores para mostrador)**')
          expect(format).not_to include('#')
        end

        it 'replaces a self-referencing Markdown link with the bare URL' do
          expect(format).to include("nuestra web:\nhttps://www.puntuaminegocio.com/productos/")
          expect(format).not_to include('[')
        end

        it 'keeps bullets, bold labels and prices for the bridge to convert' do
          expect(format).to include('* **1 Tarjeta NFC:** 18,90 €')
        end
      end

      it 'flattens headings that are already bold without doubling the markers' do
        expect(described_class.format('## **Precios**', channel_type: 'Channel::Api')).to eq('**Precios**')
      end

      it 'handles headings with trailing hashes and up to three leading spaces' do
        expect(described_class.format('   # Título ##', channel_type: 'Channel::Api')).to eq('**Título**')
      end

      it 'does not treat a hashtag mid-line or a "#1" as a heading' do
        text = 'Somos el #1 en reseñas #google'

        expect(described_class.format(text, channel_type: 'Channel::Api')).to eq(text)
      end

      it 'keeps the label when the link text is not the URL' do
        text = 'Pide en la [tienda online](https://www.example.com/shop "Tienda") hoy.'

        expect(described_class.format(text, channel_type: 'Channel::Api'))
          .to eq('Pide en la tienda online (https://www.example.com/shop) hoy.')
      end

      it 'treats a label that is the same host without scheme or trailing slash as the URL' do
        expect(described_class.format('[www.example.com/shop](https://example.com/shop/)', channel_type: 'Channel::Api'))
          .to eq('https://example.com/shop/')
      end

      it 'drops the brackets of an autolink and the alt text of an image' do
        expect(described_class.format('Mira <https://example.com/a>', channel_type: 'Channel::Api')).to eq('Mira https://example.com/a')
        expect(described_class.format('![foto](https://example.com/a.png)', channel_type: 'Channel::Api')).to eq('https://example.com/a.png')
      end

      it 'removes horizontal rules and collapses the blank lines they leave behind' do
        text = "Hola\n\n---\n\nAdiós"

        expect(described_class.format(text, channel_type: 'Channel::Api')).to eq("Hola\n\nAdiós")
      end

      it 'leaves ** and ~~ alone because the Evolution bridge converts them itself' do
        text = 'Es **muy** ~~caro~~ barato'

        expect(described_class.format(text, channel_type: 'Channel::Api')).to eq(text)
      end
    end

    context 'with a Channel::Whatsapp inbox (Cloud API, no bridge)' do
      it 'uses WhatsApp single-character markers for bold and strikethrough' do
        text = "### Oferta\nEs **muy** ~~caro~~ barato"

        expect(described_class.format(text, channel_type: 'Channel::Whatsapp')).to eq("*Oferta*\nEs *muy* ~caro~ barato")
      end
    end

    context 'with an SMS inbox' do
      it 'strips emphasis markers entirely' do
        text = "## Oferta\nEs **muy** ~~caro~~ barato: [web](https://x.io)"

        expect(described_class.format(text, channel_type: 'Channel::Sms')).to eq("Oferta\nEs muy caro barato: web (https://x.io)")
      end
    end
  end
end
