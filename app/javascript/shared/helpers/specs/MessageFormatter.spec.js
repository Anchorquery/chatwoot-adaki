import MessageFormatter from '../MessageFormatter';

describe('#MessageFormatter', () => {
  describe('content with links', () => {
    it('should format correctly', () => {
      const message =
        'Adaki is an opensource tool. [Adaki](https://www.adaki.net)';
      expect(new MessageFormatter(message).formattedMessage).toMatch(
        '<p>Adaki is an opensource tool. <a href="https://www.adaki.net" class="link" rel="noreferrer noopener nofollow" target="_blank">Adaki</a></p>'
      );
    });
    it('should format correctly', () => {
      const message = 'Adaki is an opensource tool. https://www.adaki.net';
      expect(new MessageFormatter(message).formattedMessage).toMatch(
        '<p>Adaki is an opensource tool. <a href="https://www.adaki.net" class="link" rel="noreferrer noopener nofollow" target="_blank">https://www.adaki.net</a></p>'
      );
    });
    it('should not convert template variables to links when linkify is disabled', () => {
      const message = 'Hey {{customer.name}}, check https://adaki.net';
      const formatter = new MessageFormatter(message, false, false, false);
      expect(formatter.formattedMessage).toMatch(
        '<p>Hey {{customer.name}}, check https://adaki.net</p>'
      );
    });
  });

  describe('parses heading to strong', () => {
    it('should format correctly', () => {
      const message = '### opensource \n ## tool';
      expect(new MessageFormatter(message).formattedMessage).toMatch(
        `<h3>opensource</h3>
<h2>tool</h2>`
      );
    });

    it('should not render a setext heading when text is followed by "--"', () => {
      const message = 'hy\n\n\\\n\\-\\-\n\nHello there';
      const result = new MessageFormatter(message).formattedMessage;
      expect(result).not.toMatch('<h2>');
      expect(result).not.toMatch('<h1>');
    });
  });

  describe('content with image and has "cw_image_height" query at the end of URL', () => {
    it('should set image height correctly', () => {
      const message =
        'Adaki is an opensource tool. ![](http://adaki.net/adaki.png?cw_image_height=24px)';
      expect(new MessageFormatter(message).formattedMessage).toMatch(
        '<p>Adaki is an opensource tool. <img src="http://adaki.net/adaki.png?cw_image_height=24px" alt="" style="height: 24px;" /></p>'
      );
    });

    it('should set image height correctly if its original size', () => {
      const message =
        'Adaki is an opensource tool. ![](http://adaki.net/adaki.png?cw_image_height=auto)';
      expect(new MessageFormatter(message).formattedMessage).toMatch(
        '<p>Adaki is an opensource tool. <img src="http://adaki.net/adaki.png?cw_image_height=auto" alt="" style="height: auto;" /></p>'
      );
    });

    it('should not set height', () => {
      const message =
        'Adaki is an opensource tool. ![](http://adaki.net/adaki.png)';
      expect(new MessageFormatter(message).formattedMessage).toMatch(
        '<p>Adaki is an opensource tool. <img src="http://adaki.net/adaki.png" alt="" /></p>'
      );
    });
  });

  describe('tweets', () => {
    it('should return the same string if not tags or @mentions', () => {
      const message = 'Adaki is an opensource tool';
      expect(new MessageFormatter(message).formattedMessage).toMatch(message);
    });

    it('should add links to @mentions', () => {
      const message =
        '@chatwootapp is an opensource tool thanks @longnonexistenttwitterusername';
      expect(
        new MessageFormatter(message, true, false).formattedMessage
      ).toMatch(
        '<p><a href="http://twitter.com/chatwootapp" class="link" rel="noreferrer noopener nofollow" target="_blank">@chatwootapp</a> is an opensource tool thanks @longnonexistenttwitterusername</p>'
      );
    });

    it('should add links to #tags', () => {
      const message = '#chatwootapp is an opensource tool';
      expect(
        new MessageFormatter(message, true, false).formattedMessage
      ).toMatch(
        '<p><a href="https://twitter.com/hashtag/chatwootapp" class="link" rel="noreferrer noopener nofollow" target="_blank">#chatwootapp</a> is an opensource tool</p>'
      );
    });
  });

  describe('private notes', () => {
    it('should return the same string if not tags or @mentions', () => {
      const message = 'Adaki is an opensource tool';
      expect(new MessageFormatter(message).formattedMessage).toMatch(message);
    });

    it('should add links to @mentions', () => {
      const message =
        '@chatwootapp is an opensource tool thanks @longnonexistenttwitterusername';
      expect(
        new MessageFormatter(message, false, true).formattedMessage
      ).toMatch(message);
    });

    it('should add links to #tags', () => {
      const message = '#chatwootapp is an opensource tool';
      expect(
        new MessageFormatter(message, false, true).formattedMessage
      ).toMatch(message);
    });
  });

  describe('plain text content', () => {
    it('returns the plain text without HTML', () => {
      const message =
        '<b>Adaki is an opensource tool. https://www.adaki.net</b>';
      expect(new MessageFormatter(message).plainText).toMatch(
        'Adaki is an opensource tool. https://www.adaki.net'
      );
    });
  });

  describe('#sanitize', () => {
    it('sanitizes markup and removes all unnecessary elements', () => {
      const message =
        '[xssLink](javascript:alert(document.cookie))\n[normalLink](https://google.com)**I am a bold text paragraph**';
      expect(new MessageFormatter(message).formattedMessage).toMatch(
        `<p>[xssLink](javascript:alert(document.cookie))<br />
<a href="https://google.com" class="link" rel="noreferrer noopener nofollow" target="_blank">normalLink</a><strong>I am a bold text paragraph</strong></p>`
      );
    });
  });
});
