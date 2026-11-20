import {
  buildAudience,
  normalizePhone,
  parsePhoneEntries,
  phoneTextFromAudience,
  removePhonesFromText,
} from '../campaignAudience';

describe('campaignAudience', () => {
  describe('normalizePhone', () => {
    it('assumes Spain for 9 digits and keeps international numbers', () => {
      expect(normalizePhone('600 111 222')).toBe('+34600111222');
      expect(normalizePhone('0034 600111222')).toBe('+34600111222');
      expect(normalizePhone('+1 (415) 555-0100')).toBe('+14155550100');
      expect(normalizePhone('12')).toBeNull();
    });
  });

  describe('parsePhoneEntries', () => {
    it('reads names, comma lists and drops duplicates', () => {
      const entries = parsePhoneEntries(
        'Ane;600111222\n600111333, 600111444\nKoldo,600111555\n600111222\nabc 99'
      );

      expect(entries.map(entry => [entry.phone, entry.name])).toEqual([
        ['+34600111222', 'Ane'],
        ['+34600111333', ''],
        ['+34600111444', ''],
        ['+34600111555', 'Koldo'],
      ]);
    });

    it('keeps invalid lines so they can be shown', () => {
      const entries = parsePhoneEntries('600111222\n123 45');
      expect(entries.filter(entry => !entry.phone).map(e => e.raw)).toEqual([
        '123 45',
      ]);
    });
  });

  it('removes numbers from the text, also inside comma lists', () => {
    expect(
      removePhonesFromText('Ane;600111222\n600111333, 600111444', [
        '+34600111222',
        '+34600111444',
      ])
    ).toBe('600111333');
  });

  it('builds the audience and reads phones back', () => {
    const audience = buildAudience({
      labelIds: [1],
      excludedLabelIds: [2],
      chats: ['1@g.us'],
      chatNames: { '1@g.us': 'Vecinos' },
      phoneText: 'Ane;600111222',
    });

    expect(audience).toEqual([
      { type: 'Label', id: 1 },
      { type: 'ExcludeLabel', id: 2 },
      { type: 'WhatsappChat', id: '1@g.us', name: 'Vecinos' },
      { type: 'Phone', id: '+34600111222', name: 'Ane' },
    ]);
    expect(phoneTextFromAudience(audience)).toBe('Ane;+34600111222');
  });
});
