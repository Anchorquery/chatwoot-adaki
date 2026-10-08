import { pairPrivateIds, sameSelection } from '../privacyHelpers';

const lid = (jid, name) => ({ jid, name, phone: null, type: 'contact' });
const phone = (number, name) => ({
  jid: `${number}@s.whatsapp.net`,
  name,
  phone: number,
  type: 'contact',
});

describe('pairPrivateIds', () => {
  it('joins a private ID and a phone with the same unique name', () => {
    const items = pairPrivateIds([
      lid('1470039@lid', 'Daniel Herrera'),
      phone('584227146464', 'daniel  herrera'),
    ]);

    expect(items).toHaveLength(1);
    expect(items[0]).toMatchObject({
      jid: '584227146464@s.whatsapp.net',
      alt_jids: ['1470039@lid'],
    });
  });

  it('keeps homonyms apart', () => {
    const items = pairPrivateIds([
      lid('1470039@lid', 'Ana'),
      phone('34600000001', 'Ana'),
      phone('34600000002', 'Ana'),
    ]);

    expect(items).toHaveLength(3);
  });

  it('never pairs on names that are just numbers', () => {
    const items = pairPrivateIds([
      lid('1470039@lid', '+34600000001'),
      phone('34600000001', '+34600000001'),
    ]);

    expect(items).toHaveLength(2);
  });
});

describe('sameSelection', () => {
  it('ignores the order of the chats', () => {
    expect(
      sameSelection(
        { mode: 'block', jids: ['a', 'b'] },
        { mode: 'block', jids: ['b', 'a'] }
      )
    ).toBe(true);
  });
});
