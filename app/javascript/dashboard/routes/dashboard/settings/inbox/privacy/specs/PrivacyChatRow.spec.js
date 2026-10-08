import { mount } from '@vue/test-utils';
import PrivacyChatRow from '../PrivacyChatRow.vue';

vi.mock('vue-i18n', () => ({ useI18n: () => ({ t: key => key }) }));

const rowText = item =>
  mount(PrivacyChatRow, {
    props: { item },
    global: { stubs: { Avatar: true } },
  }).text();

describe('PrivacyChatRow', () => {
  it('shows the phone under the name', () => {
    const text = rowText({
      jid: '34666441009@s.whatsapp.net',
      name: 'Andoni',
      phone: '34666441009',
      type: 'contact',
    });

    expect(text).toContain('Andoni');
    expect(text).toContain('+34666441009');
  });

  // Los dígitos de un "@lid" son opacos: no se enseñan como si fueran algo.
  it('labels a private WhatsApp ID instead of its digits', () => {
    const text = rowText({
      jid: '274804942893195@lid',
      name: 'Levantebox',
      phone: null,
      type: 'contact',
    });

    expect(text).toContain('Levantebox');
    expect(text).toContain('PRIVACY_FILTER.PRIVATE_ID');
    expect(text).not.toContain('274804942893195');
  });

  it('names an unnamed private ID as an unnamed contact', () => {
    const text = rowText({
      jid: '221393400672384@lid',
      name: '221393400672384@lid',
      phone: null,
      type: 'contact',
    });

    expect(text).toContain('PRIVACY_FILTER.UNNAMED');
    expect(text).not.toContain('221393400672384');
  });

  it('keeps the ID of a group visible', () => {
    const text = rowText({
      jid: '120363@g.us',
      name: 'Familia',
      phone: null,
      type: 'group',
    });

    expect(text).toContain('120363@g.us');
  });
});
